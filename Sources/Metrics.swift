import Darwin
import Foundation

struct SystemMetrics {
    let cpuPercent: Double?
    let memoryUsedBytes: UInt64
    let memoryTotalBytes: UInt64
    let receivedBytesPerSecond: Double?
    let sentBytesPerSecond: Double?
    let networkInterfaces: [String]
    /// Actual monotonic time between readings; nil for a first/reset sample.
    var sampleInterval: TimeInterval? = nil
    /// False if the VM read failed; memoryUsedBytes then retains the last good value.
    var memoryReadingAvailable: Bool = true
    /// Same VM read as the displayed value; useful for comparing accounting.
    var memoryDiagnostics: [String: UInt64]? = nil
}

// This sampler owns no timer or background queue. Its caller must serialize access
// and call reset() at sleep/wake. No subprocesses, network requests, or writes.
final class MetricsSampler {
    private var previous: MetricsCounters?
    private var lastMemoryUsed: UInt64 = 0
    private let maximumInterval: TimeInterval

    init(maximumInterval: TimeInterval = 120) {
        self.maximumInterval = maximumInterval
    }

    func reset() { previous = nil }

    func sample() -> SystemMetrics {
        let now = ProcessInfo.processInfo.systemUptime
        let host = mach_host_self()
        defer { mach_port_deallocate(mach_task_self_, host) }
        let cpu = Self.readCPU(host: host)
        let network = Self.readNetwork()
        let total = ProcessInfo.processInfo.physicalMemory
        let memory = Self.readMemory(host: host, total: total)
        if let memory { lastMemoryUsed = memory.used }
        let current = MetricsCounters(time: now, cpu: cpu, network: network)
        let delta = MetricsDelta.compute(previous: previous, current: current,
                                         maximumInterval: maximumInterval)
        previous = current
        return SystemMetrics(cpuPercent: delta.cpuPercent,
                             memoryUsedBytes: lastMemoryUsed,
                             memoryTotalBytes: total,
                             receivedBytesPerSecond: delta.received,
                             sentBytesPerSecond: delta.sent,
                             networkInterfaces: network.map { $0.keys.sorted() } ?? [],
                             sampleInterval: delta.interval,
                             memoryReadingAvailable: memory != nil,
                             memoryDiagnostics: memory?.diagnostics)
    }

    private static func readCPU(host: host_t) -> [UInt64]? {
        var info = host_cpu_load_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info_data_t>.size /
                                          MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(host, HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        // Darwin CPU_STATE_USER, SYSTEM, IDLE, NICE order.
        return [UInt64(info.cpu_ticks.0), UInt64(info.cpu_ticks.1),
                UInt64(info.cpu_ticks.2), UInt64(info.cpu_ticks.3)]
    }

    private static func readMemory(host: host_t, total: UInt64) -> (used: UInt64, diagnostics: [String: UInt64])? {
        var info = vm_statistics64_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size /
                                          MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(host, HOST_VM_INFO64, $0, &count)
            }
        }
        var pageSize: vm_size_t = 0
        guard result == KERN_SUCCESS,
              host_page_size(host, &pageSize) == KERN_SUCCESS, pageSize > 0 else { return nil }
        let page = UInt64(pageSize)
        let free = UInt64(info.free_count)
        let speculative = UInt64(info.speculative_count)
        let external = UInt64(info.external_page_count)
        let purgeable = UInt64(info.purgeable_count)
        let internalPages = UInt64(info.internal_page_count)
        let wired = UInt64(info.wire_count)
        let compressed = UInt64(info.compressor_page_count)
        let used = MetricsDelta.memoryUsed(freePages: free, speculativePages: speculative,
                                          externalPages: external, purgeablePages: purgeable,
                                          pageSize: page, total: total)
        // Approximate physical-use accounting, not a promise of exact Activity
        // Monitor parity. Physical RAM can include carveouts absent from VM pools.
        // XNU host.c includes speculative pages in free_count; vm_resident.c also
        // includes them in pageable_external, so subtract their overlap once.
        let freeOnly = free > speculative ? free - speculative : 0
        func bytes(_ pages: UInt64) -> UInt64 { MetricsDelta.saturatingBytes([pages], pageSize: page) }
        let accounted = MetricsDelta.saturatingBytes([freeOnly, external, internalPages, wired, compressed], pageSize: page)
        let legacy = MetricsDelta.saturatingBytes([internalPages > purgeable ? internalPages - purgeable : 0,
                                                  wired, compressed], pageSize: page)
        return (used, ["pageSizeBytes": page, "freeIncludingSpeculativeBytes": bytes(free),
                       "speculativeBytes": bytes(speculative), "fileBackedBytes": bytes(external),
                       "purgeableBytes": bytes(purgeable), "anonymousBytes": bytes(internalPages),
                       "wiredBytes": bytes(wired), "compressedBytes": bytes(compressed),
                       "freeExcludingSpeculativeBytes": bytes(freeOnly),
                       "estimatedCacheBytes": MetricsDelta.saturatingBytes([external, purgeable], pageSize: page),
                       "legacyUsedBytes": min(total, legacy),
                       "physicalRemainderBytes": total > accounted ? total - accounted : 0])
    }

    private static func readNetwork() -> [String: NetworkCounter]? {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0 else { return nil }
        defer { if let head { freeifaddrs(head) } }
        var values: [String: NetworkCounter] = [:]
        var node = head
        while let current = node {
            let entry = current.pointee
            node = entry.ifa_next
            guard let address = entry.ifa_addr,
                  address.pointee.sa_family == UInt8(AF_LINK),
                  entry.ifa_flags & UInt32(IFF_LOOPBACK) == 0,
                  entry.ifa_flags & UInt32(IFF_UP) != 0,
                  let namePointer = entry.ifa_name,
                  let data = entry.ifa_data else { continue }
            let name = String(cString: namePointer)
            // Include en0/en1/etc only: avoids adding utun/bridge/awdl traffic on
            // top of the physical link. VPN-only/other naming is not measured.
            guard MetricsDelta.isPhysicalInterfaceName(name) else { continue }
            let counters = data.assumingMemoryBound(to: if_data.self).pointee
            values[name] = NetworkCounter(received: UInt64(counters.ifi_ibytes),
                                          sent: UInt64(counters.ifi_obytes))
        }
        return values
    }
}

struct NetworkCounter {
    let received: UInt64
    let sent: UInt64
}

struct MetricsCounters {
    let time: TimeInterval
    let cpu: [UInt64]?
    let network: [String: NetworkCounter]?
}

struct MetricsDelta {
    var cpuPercent: Double? = nil
    var received: Double? = nil
    var sent: Double? = nil
    var interval: TimeInterval? = nil

    static func compute(previous: MetricsCounters?, current: MetricsCounters,
                        maximumInterval: TimeInterval = 120) -> MetricsDelta {
        guard let previous else { return MetricsDelta() }
        let elapsed = current.time - previous.time
        guard elapsed.isFinite, elapsed > 0, elapsed <= maximumInterval else {
            return MetricsDelta()
        }
        var result = MetricsDelta(interval: elapsed)
        if let before = previous.cpu, let after = current.cpu,
           before.count == 4, after.count == 4,
           zip(before, after).allSatisfy({ $1 >= $0 }) {
            let ticks = zip(before, after).map { Double($1 - $0) }
            let total = ticks.reduce(0, +)
            if total > 0 {
                result.cpuPercent = min(100, max(0, (total - ticks[2]) / total * 100))
            }
        }
        if let before = previous.network, let after = current.network,
           !after.isEmpty, Set(before.keys) == Set(after.keys) {
            var received: Double = 0
            var sent: Double = 0
            for (name, value) in after {
                guard let old = before[name], value.received >= old.received,
                      value.sent >= old.sent else { return result }
                // getifaddrs exposes 32-bit if_data counters. A decrease may be
                // wrap, interface reset or reconnect: discard rather than invent
                // traffic. Per-interface checking avoids aggregate masking.
                received += Double(value.received - old.received)
                sent += Double(value.sent - old.sent)
            }
            result.received = received / elapsed
            result.sent = sent / elapsed
        }
        return result
    }

    static func isPhysicalInterfaceName(_ name: String) -> Bool {
        name.hasPrefix("en") && !name.dropFirst(2).isEmpty &&
            name.dropFirst(2).allSatisfy { $0.isASCII && $0.isNumber }
    }

    /// Physical RAM minus free and reclaimable cache, including physical
    /// reservations outside the VM page pools. Free/speculative overlap is
    /// deducted exactly once. This remains an estimate from one VM snapshot.
    static func memoryUsed(freePages: UInt64, speculativePages: UInt64,
                           externalPages: UInt64, purgeablePages: UInt64,
                           pageSize: UInt64, total: UInt64) -> UInt64 {
        let freeOnly = freePages > speculativePages ? freePages - speculativePages : 0
        let available = saturatingBytes([freeOnly, externalPages, purgeablePages], pageSize: pageSize)
        return total > available ? total - available : 0
    }

    static func saturatingBytes(_ counts: [UInt64], pageSize: UInt64) -> UInt64 {
        var pages: UInt64 = 0
        for count in counts {
            let (sum, overflow) = pages.addingReportingOverflow(count)
            if overflow { return UInt64.max }
            pages = sum
        }
        let (bytes, overflow) = pages.multipliedReportingOverflow(by: pageSize)
        return overflow ? UInt64.max : bytes
    }
}
