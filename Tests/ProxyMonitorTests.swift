import Foundation

// Pure in-memory fixtures: no installed app, user configuration, network, or
// local controller is accessed. Node labels below are deliberately synthetic.
@main
struct ProxyMonitorTests {
    static func main() {
        var checks = 0
        func check(_ condition: @autoclosure () -> Bool, _ message: String) {
            precondition(condition(), message)
            checks += 1
        }
        let fixture: [String: Any] = ["proxies": [
            "Proxies": ["type": "Selector", "now": "Auto Group"],
            "Auto Group": ["type": "URLTest", "now": "Example Node A"],
            "GLOBAL": ["type": "Selector", "now": "Example Node B"],
            "Fallback Group": ["type": "Fallback", "now": "DIRECT"],
            "Load Group": ["type": "LoadBalance", "now": "Example Node C"],
            "Loop": ["type": "Selector", "now": "Loop"],
            "Two-Cycle A": ["type": "Selector", "now": "Two-Cycle B"],
            "Two-Cycle B": ["type": "Selector", "now": "Two-Cycle A"],
            "Ordinary Node": ["type": "Shadowsocks", "now": "Not A Group"],
            "Missing Choice": ["type": "Selector"],
            "Invalid Choice": ["type": "Selector", "now": 123],
            "Unknown Type": ["type": "FutureType", "now": "Example Node Z"]
        ]]
        let rule = ProxyMonitor.selections(from: fixture, mode: "rule")
        check(rule.first?.group == "Proxies", "rule mode labels the preferred selector explicitly")
        check(rule.first?.selectedNode == "Auto Group", "preserve the chosen group for UI context")
        check(rule.first?.resolvedNode == "Example Node A", "follow nested selected groups")
        check(rule.first?.type == "Selector", "preserve group type for truthful labels")
        check(rule.last?.group == "GLOBAL", "inactive global selection must not override rule selector")
        check(rule.count == 8, "only known groups with a string selection are included")
        check(rule.contains { $0.group == "Loop" && $0.resolvedNode == "Loop" }, "self cycles terminate")
        check(rule.contains { $0.group == "Two-Cycle A" }, "multi-group cycles terminate")
        check(rule.contains { $0.group == "Fallback Group" && $0.resolvedNode == "DIRECT" }, "direct routes remain direct")
        check(rule.contains { $0.group == "Load Group" && $0.type == "LoadBalance" }, "load-balanced type is retained")
        let global = ProxyMonitor.selections(from: fixture, mode: "GLOBAL")
        check(global.first?.group == "GLOBAL", "global mode is case-insensitive")
        check(global.first?.resolvedNode == "Example Node B", "global and rule choices remain distinct")
        check(ProxyMonitor.selections(from: fixture, mode: nil).first?.group == "Proxies", "missing mode never silently chooses GLOBAL")
        check(ProxyMonitor.selections(from: [:], mode: nil).isEmpty, "missing proxy object is empty")
        check(ProxyMonitor.selections(from: ["proxies": []], mode: nil).isEmpty, "invalid proxy object is empty")
        check(ProxyMonitor.selections(from: ["proxies": [String: Any]()], mode: nil).isEmpty, "empty controller groups are empty")
        let unicode: [String: Any] = ["proxies": ["节点选择": ["type": "Selector", "now": "示例节点"]]]
        check(ProxyMonitor.selections(from: unicode, mode: "rule").first?.resolvedNode == "示例节点", "Unicode labels survive parsing")
        let repeated = ProxyMonitor.selections(from: fixture, mode: "rule").map(\.group)
        check(repeated == rule.map(\.group), "ordering is stable across equivalent responses")
        print("ProxyMonitorTests: \(checks) checks passed")
    }
}
