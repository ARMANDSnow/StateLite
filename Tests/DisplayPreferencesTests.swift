import Foundation

@main struct DisplayPreferencesTests {
    static func main() {
        precondition(DisplayPreferences.sanitize([]) == [.cpu, .temperature])
        precondition(DisplayPreferences.sanitize(["old", "memory"]) == [.memory])
        precondition(DisplayPreferences.sanitize(["memory", "memory", "cpu", "upload"]) == [.memory, .cpu])
        precondition(DisplayPreferences.sanitize(["upload", "temperature"]) == [.upload, .temperature])
        precondition(DisplayPreferences.sanitize(["invalid"]) == [.cpu, .temperature])
        let defaults = DisplayPreferences.sanitizeLayout(order: [], hidden: [])
        precondition(defaults == ModuleLayout(order: [.system, .thermal, .network, .proxy], hidden: []))
        let partial = DisplayPreferences.sanitizeLayout(order: ["proxy", "gpu", "proxy", "system"], hidden: ["network", "battery"])
        precondition(partial.order == [.proxy, .system, .thermal, .network])
        precondition(partial.hidden == [.network])
        precondition(partial.visible == [.proxy, .system, .thermal])
        print("DisplayPreferencesTests: 9 checks passed")
    }
}
