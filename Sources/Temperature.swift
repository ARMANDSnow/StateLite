import Foundation
import Darwin

struct TemperatureReading {
    let celsius: Double?
    let source: String
    let detail: String
}

/// Read-only Apple Silicon CPU sensor sampling. Use from one serial queue.
/// Private IOKit interfaces are not stable macOS APIs and may be unavailable.
/// ABI and sensor naming references (independent implementation):
/// https://github.com/exelban/stats/blob/master/Modules/Sensors/bridge.h
/// https://github.com/exelban/stats/blob/master/Modules/Sensors/readers.swift
final class TemperatureSampler {
    private typealias Create = @convention(c) (CFAllocator?) -> Unmanaged<CFTypeRef>?
    private typealias Match = @convention(c) (CFTypeRef, CFDictionary) -> Int32
    private typealias Services = @convention(c) (CFTypeRef) -> Unmanaged<CFArray>?
    private typealias Property = @convention(c) (UnsafeRawPointer, CFString) -> Unmanaged<CFTypeRef>?
    private typealias Event = @convention(c) (UnsafeRawPointer, Int64, Int32, Int64) -> Unmanaged<CFTypeRef>?
    private typealias Value = @convention(c) (CFTypeRef, Int32) -> Double

    private var library: UnsafeMutableRawPointer?
    private var client: CFTypeRef?
    // Retain the array because cached service pointers belong to it.
    private var serviceArray: CFArray?
    private var cpuServices: [(pointer: UnsafeRawPointer, name: String)] = []
    private var copyEvent: Event?
    private var getValue: Value?
    private var discovered = false
    private var unavailableReason = "尚未发现传感器"
    private var smc: OpaquePointer?
    private var smcKeys: [String] = []
    private var retryDiscoveryAt = Date.distantFuture

    deinit {
        releaseConnections()
    }

    private func releaseConnections() {
        cpuServices.removeAll()
        serviceArray = nil
        client = nil
        if let library { dlclose(library) }
        if let smc { SLTemperatureClose(smc) }
        library = nil
        smc = nil
        smcKeys.removeAll()
    }

    /// Caller may invoke on its sampling queue after wake to discard stale handles.
    func reset() {
        releaseConnections()
        discovered = false
        retryDiscoveryAt = .distantFuture
    }

    private func failed(source: String, detail: String) -> TemperatureReading {
        if retryDiscoveryAt == .distantFuture {
            retryDiscoveryAt = Date().addingTimeInterval(60)
        }
        return TemperatureReading(celsius: nil, source: source, detail: detail)
    }

    func sample() -> TemperatureReading {
        if !discovered || Date() >= retryDiscoveryAt {
            releaseConnections()
            discovered = true
            retryDiscoveryAt = .distantFuture
            discover()
            if cpuServices.isEmpty { discoverSMC() }
        }
        if let smc, !smcKeys.isEmpty {
            let values = smcKeys.compactMap { key -> Double? in
                var value = 0.0
                return key.withCString { SLTemperatureRead(smc, $0, &value) } ? value : nil
            }
            if values.isEmpty {
                return failed(source: "IOKit SMC", detail: "当前没有有效 CPU 温度读数；将在低频重试，不显示旧值或估计值")
            }
            retryDiscoveryAt = .distantFuture
            let subset = smcKeys.allSatisfy { $0.hasPrefix("Te") } ? "CPU 能效核心传感器" : "可用 CPU 核心传感器"
            return TemperatureReading(
                celsius: values.reduce(0, +) / Double(values.count),
                source: "\(subset)均值 · SMC",
                detail: "\(values.count)/\(smcKeys.count) 个\(subset)均值（\(smcKeys.joined(separator: ","))）；不代表全部核心或热点温度。非公开 AppleSMC 只读接口。"
            )
        }
        guard !cpuServices.isEmpty, let copyEvent, let getValue else {
            return failed(source: "IOKit HID/SMC", detail: unavailableReason)
        }
        var values: [Double] = []
        for sensor in cpuServices {
            guard let event = copyEvent(sensor.pointer, 15, 0, 0)?.takeRetainedValue() else { continue }
            let value = getValue(event, 15 << 16)
            // Reject absent/invalid readings; never substitute an estimated temperature.
            guard value.isFinite, value >= 10, value <= 125 else { continue }
            values.append(value)
        }
        guard !values.isEmpty else {
            return failed(source: "IOKit HID", detail: "已发现 CPU 传感器，但当前没有有效读数；私有接口可能受系统限制")
        }
        retryDiscoveryAt = .distantFuture
        return TemperatureReading(
            celsius: values.reduce(0, +) / Double(values.count),
            source: "CPU 传感器均值 · HID",
            detail: "\(values.count)/\(cpuServices.count) 个 pACC/eACC MTR 温度传感器的有效读数均值；不是 CPU 热点或单一封装温度。使用非公开 IOKit 接口。"
        )
    }

    private func discoverSMC() {
        // Model-specific CPU labels are empirical, not an Apple API contract:
        // https://github.com/exelban/stats/blob/master/Modules/Sensors/values.swift
        var bytes = [CChar](repeating: 0, count: 128)
        var length = bytes.count
        guard sysctlbyname("machdep.cpu.brand_string", &bytes, &length, nil, 0) == 0 else { return }
        let chip = String(cString: bytes)
        let candidates: [String]
        if chip.hasPrefix("Apple M4 Pro") {
            // Upstream's M4-family table labels Tp* as performance-core sensors,
            // but this machine exposes unstable near-zero Tp* readings. A range
            // filter cannot establish their meaning. Keep a fixed conservative
            // set of locally cross-checked efficiency-core channels instead.
            candidates = ["Te05", "Te0S"]
        } else if chip.hasPrefix("Apple M4") {
            candidates = ["Te05", "Te0S", "Te09", "Te0H", "Tp01", "Tp05", "Tp09", "Tp0D", "Tp0V", "Tp0Y", "Tp0b", "Tp0e"]
        } else if chip.hasPrefix("Apple M3") {
            candidates = ["Te05", "Te0L", "Te0P", "Te0S", "Tf04", "Tf09", "Tf0A", "Tf0B", "Tf0D", "Tf0E", "Tf44", "Tf49", "Tf4A", "Tf4B", "Tf4D", "Tf4E"]
        } else if chip.hasPrefix("Apple M2") {
            candidates = ["Tp1h", "Tp1t", "Tp1p", "Tp1l", "Tp01", "Tp05", "Tp09", "Tp0D", "Tp0X", "Tp0b", "Tp0f", "Tp0j"]
        } else if chip.hasPrefix("Apple M1") {
            candidates = ["Tp09", "Tp0T", "Tp01", "Tp05", "Tp0D", "Tp0H", "Tp0L", "Tp0P", "Tp0X", "Tp0b"]
        } else {
            unavailableReason += "；没有此芯片的可靠 SMC 键映射"
            return
        }
        guard let connection = SLTemperatureOpen() else {
            unavailableReason += "；AppleSMC 只读连接不可用"
            return
        }
        smc = connection
        smcKeys = candidates.filter { key in
            var value = 0.0
            return key.withCString { SLTemperatureRead(connection, $0, &value) }
        }
        if smcKeys.isEmpty { unavailableReason += "；已知 CPU SMC 键也无有效读数" }
    }

    private func discover() {
        #if !arch(arm64)
        unavailableReason = "当前温度采样仅支持 Apple Silicon"
        return
        #else
        guard let handle = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_LAZY | RTLD_LOCAL) else {
            unavailableReason = "无法加载 IOKit"
            return
        }
        library = handle
        func load<T>(_ name: String, as type: T.Type) -> T? {
            guard let symbol = dlsym(handle, name) else { return nil }
            return unsafeBitCast(symbol, to: type)
        }
        guard let create = load("IOHIDEventSystemClientCreate", as: Create.self),
              let match = load("IOHIDEventSystemClientSetMatching", as: Match.self),
              let services = load("IOHIDEventSystemClientCopyServices", as: Services.self),
              let property = load("IOHIDServiceClientCopyProperty", as: Property.self),
              let event = load("IOHIDServiceClientCopyEvent", as: Event.self),
              let value = load("IOHIDEventGetFloatValue", as: Value.self) else {
            unavailableReason = "此 macOS 未提供所需的非公开温度接口"
            return
        }
        guard let created = create(kCFAllocatorDefault)?.takeRetainedValue() else {
            unavailableReason = "无法创建只读温度传感器客户端"
            return
        }
        client = created
        _ = match(created, ["PrimaryUsagePage": 0xff00, "PrimaryUsage": 5] as CFDictionary)
        guard let found = services(created)?.takeRetainedValue() else {
            unavailableReason = "系统没有返回温度传感器"
            return
        }
        serviceArray = found
        copyEvent = event
        getValue = value
        for index in 0..<CFArrayGetCount(found) {
            guard let pointer = CFArrayGetValueAtIndex(found, index),
                  let product = property(pointer, "Product" as CFString)?.takeRetainedValue() as? String else { continue }
            if product.hasPrefix("pACC MTR Temp") || product.hasPrefix("eACC MTR Temp") {
                cpuServices.append((pointer, product))
            }
        }
        unavailableReason = "未发现可识别的 CPU 温度传感器（扫描 \(CFArrayGetCount(found)) 个温度服务）；不会用其他部件温度替代"
        #endif
    }
}
