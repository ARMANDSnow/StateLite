import AppKit
import Darwin
import Foundation
import SystemConfiguration

struct ProxySnapshot {
    let systemProxyEnabled: Bool
    let clashRunning: Bool
    /// Enabled proxy endpoints only; never contains configuration credentials.
    let endpoints: [String]
}

struct ProxySelection {
    let group: String
    let selectedNode: String
    /// Follows nested groups, but is not a claim about every request's route.
    let resolvedNode: String
    let type: String
}

struct ProxyControllerSnapshot {
    let available: Bool
    let status: String
    let mode: String?
    let selections: [ProxySelection]
    let updatedAt: Date?
}

/// Owns no timer. Call sample() on the existing UI schedule and refreshController()
/// when opening the panel. Controller results are cached for at least 15 seconds.
/// Only GET /configs and GET /proxies are permitted; this never changes routing.
final class ProxyMonitor {
    static let bundleIdentifier = "io.github.clash-verge-rev.clash-verge-rev"
    private let queue = DispatchQueue(label: "StateLite.proxy-reader", qos: .utility)
    private var cached: ProxyControllerSnapshot?
    private var lastRefresh: TimeInterval = -.infinity
    private let minimumRefreshInterval: TimeInterval = 15

    func sample() -> ProxySnapshot {
        let settings = SCDynamicStoreCopyProxies(nil) as? [String: Any] ?? [:]
        var endpoints: [String] = []
        for (enabled, host, port, label) in [
            ("HTTPEnable", "HTTPProxy", "HTTPPort", "HTTP"),
            ("HTTPSEnable", "HTTPSProxy", "HTTPSPort", "HTTPS"),
            ("SOCKSEnable", "SOCKSProxy", "SOCKSPort", "SOCKS")
        ] {
            if (settings[enabled] as? NSNumber)?.boolValue == true,
               let address = settings[host] as? String,
               let number = settings[port] as? NSNumber {
                endpoints.append("\(label) \(address):\(number.intValue)")
            }
        }
        let automatic = (settings["ProxyAutoConfigEnable"] as? NSNumber)?.boolValue == true ||
            (settings["ProxyAutoDiscoveryEnable"] as? NSNumber)?.boolValue == true
        if automatic { endpoints.append("自动代理") }
        return ProxySnapshot(systemProxyEnabled: !endpoints.isEmpty,
                             clashRunning: !NSRunningApplication.runningApplications(
                                withBundleIdentifier: Self.bundleIdentifier).isEmpty,
                             endpoints: endpoints)
    }

    func openClash(completion: ((Bool) -> Void)? = nil) {
        DispatchQueue.main.async {
            guard let url = NSWorkspace.shared.urlForApplication(
                withBundleIdentifier: Self.bundleIdentifier) else {
                completion?(false); return
            }
            NSWorkspace.shared.openApplication(at: url,
                configuration: NSWorkspace.OpenConfiguration()) { app, _ in
                DispatchQueue.main.async { completion?(app != nil) }
            }
        }
    }

    /// Callback always runs on main. force is for an explicit user refresh only.
    func refreshController(force: Bool = false,
                           completion: @escaping (ProxyControllerSnapshot) -> Void) {
        queue.async {
            let now = ProcessInfo.processInfo.systemUptime
            if !force, now - self.lastRefresh < self.minimumRefreshInterval,
               let cached = self.cached {
                DispatchQueue.main.async { completion(cached) }
                return
            }
            let result = self.readController()
            self.cached = result
            self.lastRefresh = ProcessInfo.processInfo.systemUptime
            DispatchQueue.main.async { completion(result) }
        }
    }

    private func readController() -> ProxyControllerSnapshot {
        do {
            let configuration = try Self.controllerConfiguration()
            let deadline = ProcessInfo.processInfo.systemUptime + 2
            // Fetch mode as context; it determines whether GLOBAL is meaningful.
            let config = try Self.request("/configs", configuration, deadline: deadline)
            let proxies = try Self.request("/proxies", configuration, deadline: deadline)
            let mode = config["mode"] as? String
            let groups = Self.selections(from: proxies, mode: mode)
            return ProxyControllerSnapshot(available: true,
                status: groups.isEmpty ? "已连接，未发现选择组" : "已连接",
                mode: mode, selections: groups, updatedAt: Date())
        } catch let failure as ProxyFailure {
            return ProxyControllerSnapshot(available: false, status: failure.message,
                                           mode: nil, selections: [], updatedAt: nil)
        } catch {
            return ProxyControllerSnapshot(available: false, status: "Clash 节点暂不可读",
                                           mode: nil, selections: [], updatedAt: nil)
        }
    }

    static func selections(from response: [String: Any], mode: String?) -> [ProxySelection] {
        guard let proxies = response["proxies"] as? [String: [String: Any]] else { return [] }
        let supported = Set(["Selector", "URLTest", "Fallback", "LoadBalance"])
        var result: [ProxySelection] = []
        for (name, proxy) in proxies {
            guard let type = proxy["type"] as? String, supported.contains(type),
                  let now = proxy["now"] as? String else { continue }
            var resolved = now
            var visited = Set([name])
            for _ in 0..<16 {
                guard !visited.contains(resolved),
                      let nested = proxies[resolved],
                      let next = nested["now"] as? String else { break }
                visited.insert(resolved)
                resolved = next
            }
            result.append(ProxySelection(group: name, selectedNode: now,
                                         resolvedNode: resolved, type: type))
        }
        func rank(_ name: String) -> Int {
            if mode?.lowercased() == "global" && name == "GLOBAL" { return 0 }
            if name == "Proxies" || name == "PROXY" || name == "节点选择" { return 1 }
            if name == "GLOBAL" { return 3 }
            return 2
        }
        return result.sorted {
            rank($0.group) == rank($1.group) ? $0.group.localizedStandardCompare($1.group) == .orderedAscending :
                rank($0.group) < rank($1.group)
        }
    }

    private enum Endpoint {
        case unix(String)
        case tcp(String, UInt16)
    }
    private struct Configuration {
        let endpoint: Endpoint
        let secret: String // lives only in memory; never logged or returned to UI
    }
    private enum ProxyFailure: Error {
        case unavailable, invalidConfiguration, timeout, permission, invalidResponse, unauthorized
        var message: String {
            switch self {
            case .unavailable: return "本地 Clash 控制接口未连接"
            case .invalidConfiguration: return "未找到安全的本地 Clash 控制接口"
            case .timeout: return "读取 Clash 节点超时"
            case .permission: return "本地 Clash 控制接口无访问权限"
            case .invalidResponse: return "Clash 控制接口返回格式异常"
            case .unauthorized: return "Clash 控制接口认证失败"
            }
        }
    }

    private static func controllerConfiguration() throws -> Configuration {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support")
            .appendingPathComponent(bundleIdentifier)
            .appendingPathComponent("clash-verge.yaml")
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size > 0 && size <= 2 * 1024 * 1024 else { throw ProxyFailure.invalidConfiguration }
        let text = try String(contentsOf: url, encoding: .utf8)
        let fields = yamlFields(text)
        let secret = fields["secret"] ?? ""
        guard !secret.contains("\r"), !secret.contains("\n"), !secret.utf8.contains(0) else {
            throw ProxyFailure.invalidConfiguration
        }
        // The service's -ext-ctl-unix argument overrides the generated YAML on
        // current Clash Verge. Its per-user path was verified against the running
        // core; require an actual socket owned by the current UID before use.
        let serviceSocket = "/var/run/clash-verge-service/users/\(getuid())/verge-mihomo.sock"
        for path in [serviceSocket, fields["external-controller-unix"] ?? ""] {
            guard path.hasPrefix("/"), !path.utf8.contains(0) else { continue }
            var information = stat()
            if lstat(path, &information) == 0,
               (information.st_mode & S_IFMT) == S_IFSOCK,
               information.st_uid == getuid() {
                return Configuration(endpoint: .unix(path), secret: secret)
            }
        }
        if let address = fields["external-controller"],
           let components = URLComponents(string: "http://" + address),
           let host = components.host, ["127.0.0.1", "::1", "[::1]"].contains(host),
           let port = components.port, port > 0, port <= 65535,
           components.user == nil, components.password == nil,
           components.path.isEmpty, components.query == nil, components.fragment == nil {
            return Configuration(endpoint: .tcp(host == "[::1]" ? "::1" : host, UInt16(port)),
                                 secret: secret)
        }
        throw ProxyFailure.invalidConfiguration
    }

    // Only the three needed top-level scalars are retained. No subscriptions,
    // node credentials, rules, or entire configuration are exposed to callers.
    private static func yamlFields(_ text: String) -> [String: String] {
        let keys = Set(["external-controller", "external-controller-unix", "secret"])
        var fields: [String: String] = [:]
        for line in text.split(separator: "\n") {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = String(line[..<colon])
            guard keys.contains(key) else { continue }
            let raw = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            let value: String
            if raw.hasPrefix("\"") {
                guard let data = raw.data(using: .utf8),
                      let decoded = try? JSONDecoder().decode(String.self, from: data) else { continue }
                value = decoded
            } else if raw.hasPrefix("'") && raw.hasSuffix("'") && raw.count >= 2 {
                value = String(raw.dropFirst().dropLast()).replacingOccurrences(of: "''", with: "'")
            } else {
                value = raw.components(separatedBy: " #")[0].trimmingCharacters(in: .whitespaces)
            }
            fields[key] = value == "null" || value == "~" ? "" : value
        }
        return fields
    }

    private static func request(_ path: String, _ configuration: Configuration,
                                deadline: TimeInterval) throws -> [String: Any] {
        guard ["/configs", "/proxies"].contains(path) else { throw ProxyFailure.invalidConfiguration }
        let descriptor: Int32
        switch configuration.endpoint {
        case .unix: descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        case .tcp(let host, _): descriptor = socket(host == "::1" ? AF_INET6 : AF_INET, SOCK_STREAM, 0)
        }
        guard descriptor >= 0 else { throw ProxyFailure.unavailable }
        defer { close(descriptor) }
        var noSignal: Int32 = 1
        _ = setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &noSignal,
                       socklen_t(MemoryLayout<Int32>.size))
        guard fcntl(descriptor, F_SETFL, O_NONBLOCK) == 0,
              fcntl(descriptor, F_SETFD, FD_CLOEXEC) == 0 else { throw ProxyFailure.unavailable }
        let result: Int32
        switch configuration.endpoint {
        case .unix(let path):
            var address = sockaddr_un()
            address.sun_family = sa_family_t(AF_UNIX)
            address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
            let bytes = Array(path.utf8) + [0]
            guard bytes.count <= MemoryLayout.size(ofValue: address.sun_path) else {
                throw ProxyFailure.invalidConfiguration
            }
            withUnsafeMutableBytes(of: &address.sun_path) { target in target.copyBytes(from: bytes) }
            result = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
                }
            }
        case .tcp(let host, let port):
            if host == "::1" {
                var address = sockaddr_in6()
                address.sin6_family = sa_family_t(AF_INET6)
                address.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
                address.sin6_port = port.bigEndian
                _ = inet_pton(AF_INET6, host, &address.sin6_addr)
                result = withUnsafePointer(to: &address) {
                    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        Darwin.connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in6>.size))
                    }
                }
            } else {
                var address = sockaddr_in()
                address.sin_family = sa_family_t(AF_INET)
                address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
                address.sin_port = port.bigEndian
                _ = inet_pton(AF_INET, host, &address.sin_addr)
                result = withUnsafePointer(to: &address) {
                    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        Darwin.connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                    }
                }
            }
        }
        if result != 0 && errno != EINPROGRESS { throw connectionFailure() }
        try ready(descriptor, event: Int16(POLLOUT), deadline: deadline)
        var error: Int32 = 0
        var errorSize = socklen_t(MemoryLayout<Int32>.size)
        guard getsockopt(descriptor, SOL_SOCKET, SO_ERROR, &error, &errorSize) == 0,
              error == 0 else { throw ProxyFailure.unavailable }
        if case .unix = configuration.endpoint {
            // Recheck the connected peer before sending the bearer token. A
            // pathname ownership check alone has a check/connect race. The
            // privileged Clash service can legitimately accept as root.
            var peerUser: uid_t = 0
            var peerGroup: gid_t = 0
            guard getpeereid(descriptor, &peerUser, &peerGroup) == 0,
                  peerUser == getuid() || peerUser == 0 else { throw ProxyFailure.permission }
        }
        let authorization = configuration.secret.isEmpty ? "" :
            "Authorization: Bearer \(configuration.secret)\r\n"
        let request = Data(("GET \(path) HTTP/1.0\r\nHost: localhost\r\n" +
                            "Connection: close\r\n" + authorization + "\r\n").utf8)
        var sent = 0
        while sent < request.count {
            try ready(descriptor, event: Int16(POLLOUT), deadline: deadline)
            let count = request.withUnsafeBytes {
                Darwin.send(descriptor, $0.baseAddress!.advanced(by: sent), request.count - sent, 0)
            }
            if count < 0 && (errno == EAGAIN || errno == EINTR) { continue }
            guard count > 0 else { throw connectionFailure() }
            sent += count
        }
        var response = Data()
        var buffer = [UInt8](repeating: 0, count: 16_384)
        while true {
            try ready(descriptor, event: Int16(POLLIN), deadline: deadline)
            let count = recv(descriptor, &buffer, buffer.count, 0)
            if count == 0 { break }
            if count < 0 && (errno == EAGAIN || errno == EINTR) { continue }
            guard count > 0 else { throw connectionFailure() }
            guard response.count + count <= 2 * 1024 * 1024 else { throw ProxyFailure.invalidResponse }
            response.append(contentsOf: buffer.prefix(count))
        }
        guard let divider = response.range(of: Data("\r\n\r\n".utf8)),
              let header = String(data: response[..<divider.lowerBound], encoding: .utf8),
              let first = header.components(separatedBy: "\r\n").first else {
            throw ProxyFailure.invalidResponse
        }
        let fields = first.split(separator: " ")
        guard fields.count >= 2 else { throw ProxyFailure.invalidResponse }
        if fields[1] == "401" || fields[1] == "403" { throw ProxyFailure.unauthorized }
        // HTTP/1.0 requests deliberately avoid chunked transfer and streaming.
        guard fields[1] == "200", !header.lowercased().contains("transfer-encoding: chunked"),
              let json = try JSONSerialization.jsonObject(with: response[divider.upperBound...])
                as? [String: Any] else { throw ProxyFailure.invalidResponse }
        return json
    }

    private static func ready(_ descriptor: Int32, event: Int16,
                              deadline: TimeInterval) throws {
        while true {
            let remaining = deadline - ProcessInfo.processInfo.systemUptime
            guard remaining > 0 else { throw ProxyFailure.timeout }
            var descriptorState = pollfd(fd: descriptor, events: event, revents: 0)
            let result = poll(&descriptorState, 1, Int32(ceil(remaining * 1000)))
            if result < 0 && errno == EINTR { continue }
            if result == 0 { throw ProxyFailure.timeout }
            guard result > 0, descriptorState.revents & Int16(POLLNVAL | POLLERR) == 0 else {
                throw ProxyFailure.unavailable
            }
            // POLLHUP still permits recv() to drain buffered bytes and see EOF.
            return
        }
    }

    private static func connectionFailure() -> ProxyFailure {
        errno == EACCES || errno == EPERM ? .permission : .unavailable
    }
}
