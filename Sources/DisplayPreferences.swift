import Foundation

enum Indicator: String, CaseIterable {
    case cpu, memory, temperature, download, upload
    var title: String {
        switch self {
        case .cpu: return "CPU 使用率"
        case .memory: return "内存使用率"
        case .temperature: return "能效核心温度"
        case .download: return "下载速度"
        case .upload: return "上传速度"
        }
    }
    /// Short label for the stacked menu bar style, where width is tight.
    var compactLabel: String {
        switch self {
        case .cpu: return "CPU"
        case .memory: return "MEM"
        case .temperature: return "TEMP"
        case .download: return "↓"
        case .upload: return "↑"
        }
    }
}

enum MenuBarStyle: String, CaseIterable { case inline, stacked }

/// Panel modules in their default order. New modules are appended here and pick up
/// a settings switch and a reorder slot automatically.
enum PanelModuleID: String, CaseIterable {
    case system, thermal, network, proxy
    var title: String {
        switch self {
        case .system: return "系统"
        case .thermal: return "散热"
        case .network: return "网络"
        case .proxy: return "代理"
        }
    }
    var summary: String {
        switch self {
        case .system: return "CPU、内存"
        case .thermal: return "能效核心温度、风扇"
        case .network: return "下载、上传"
        case .proxy: return "Clash Verge 节点"
        }
    }
}

struct ModuleLayout: Equatable {
    var order: [PanelModuleID]
    var hidden: Set<PanelModuleID>
    var visible: [PanelModuleID] { order.filter { !hidden.contains($0) } }
}

struct DisplayPreferences {
    static let key = "menuBarIndicators"
    static let styleKey = "menuBarStyle"
    static let orderKey = "panelModuleOrder"
    static let hiddenKey = "panelHiddenModules"
    static func sanitize(_ values: [String]) -> [Indicator] {
        var result: [Indicator] = []
        for raw in values {
            if let item = Indicator(rawValue: raw), !result.contains(item) { result.append(item) }
            if result.count == 2 { break }
        }
        return result.isEmpty ? [.cpu, .temperature] : result
    }
    static func load() -> [Indicator] {
        sanitize(UserDefaults.standard.stringArray(forKey: key) ?? [])
    }
    static func save(_ items: [Indicator]) {
        UserDefaults.standard.set(sanitize(items.map(\.rawValue)).map(\.rawValue), forKey: key)
    }

    static func loadStyle() -> MenuBarStyle {
        MenuBarStyle(rawValue: UserDefaults.standard.string(forKey: styleKey) ?? "") ?? .inline
    }
    static func saveStyle(_ style: MenuBarStyle) { UserDefaults.standard.set(style.rawValue, forKey: styleKey) }

    /// Unknown and duplicate ids are dropped; modules missing from a saved order keep their default slot at the end.
    static func sanitizeLayout(order: [String], hidden: [String]) -> ModuleLayout {
        var result: [PanelModuleID] = []
        for raw in order { if let id = PanelModuleID(rawValue: raw), !result.contains(id) { result.append(id) } }
        result += PanelModuleID.allCases.filter { !result.contains($0) }
        return ModuleLayout(order: result, hidden: Set(hidden.compactMap(PanelModuleID.init(rawValue:))))
    }
    static func loadLayout() -> ModuleLayout {
        let defaults = UserDefaults.standard
        return sanitizeLayout(order: defaults.stringArray(forKey: orderKey) ?? [], hidden: defaults.stringArray(forKey: hiddenKey) ?? [])
    }
    static func saveLayout(_ layout: ModuleLayout) {
        let clean = sanitizeLayout(order: layout.order.map(\.rawValue), hidden: layout.hidden.map(\.rawValue))
        UserDefaults.standard.set(clean.order.map(\.rawValue), forKey: orderKey)
        UserDefaults.standard.set(PanelModuleID.allCases.filter(clean.hidden.contains).map(\.rawValue), forKey: hiddenKey)
    }
}
