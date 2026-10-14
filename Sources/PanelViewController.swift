import AppKit

enum ProxyState { case checking, connected, degraded, notRunning }

/// Fan state as the panel shows it. The confirmation step lives in the panel itself.
enum FanPhase: Equatable {
    case reading, unavailable, system, authorizing, restoring
    case custom
    var boosting: Bool { self == .custom }
}

/// Menu bar text shared by the status item and the settings preview.
enum MenuBarLabel {
    static func parts(_ indicators: [Indicator], metrics: SystemMetrics, temperature: TemperatureReading) -> [(Indicator, String)] {
        indicators.map { item in
            switch item {
            case .cpu: return (item, percentText(metrics.cpuPercent))
            case .memory: return (item, metrics.memoryReadingAvailable ? percentText(memoryPercent(metrics)) : "—")
            case .temperature: return (item, temperature.celsius.map { String(format: "%.0f°C", $0) } ?? "—°C")
            case .download: return (item, metrics.receivedBytesPerSecond.map { byteText($0, rate: true) } ?? "—")
            case .upload: return (item, metrics.sentBytesPerSecond.map { byteText($0, rate: true) } ?? "—")
            }
        }
    }
    static func inline(_ parts: [(Indicator, String)]) -> String {
        parts.map { item, value in item == .temperature ? value : item.compactLabel + " " + value }.joined(separator: " · ")
    }
    /// Two lines in one menu bar slot. Template images let the system pick the menu bar text color.
    static func stacked(_ parts: [(Indicator, String)], height: CGFloat, color: NSColor? = nil) -> NSImage {
        let ink = color ?? .black
        let font = NSFont.monospacedDigitSystemFont(ofSize: 9.5, weight: .semibold)
        let labelFont = NSFont.systemFont(ofSize: 9, weight: .medium)
        let lines = parts.map { item, value in
            (NSAttributedString(string: item.compactLabel, attributes: [.font: labelFont, .foregroundColor: ink.withAlphaComponent(0.62)]),
             NSAttributedString(string: value, attributes: [.font: font, .foregroundColor: ink]))
        }
        let labelWidth = lines.map { $0.0.size().width }.max() ?? 0
        let valueWidth = lines.map { $0.1.size().width }.max() ?? 0
        // Rounded up so the item does not shift with every digit change.
        let width = ceil((labelWidth + 5 + valueWidth) / 4) * 4
        let lineHeight: CGFloat = 10.5
        let image = NSImage(size: NSSize(width: max(width, 1), height: height), flipped: true) { _ in
            let top = (height - lineHeight * CGFloat(lines.count)) / 2
            for (index, line) in lines.enumerated() {
                let y = top + lineHeight * CGFloat(index) - 1
                line.0.draw(at: NSPoint(x: 0, y: y + 0.5))
                line.1.draw(at: NSPoint(x: width - line.1.size().width, y: y))
            }
            return true
        }
        image.isTemplate = color == nil
        return image
    }
    static func memoryPercent(_ metrics: SystemMetrics) -> Double {
        Double(metrics.memoryUsedBytes) / max(1, Double(metrics.memoryTotalBytes)) * 100
    }
}

final class PanelViewController: NSViewController {
    static let width: CGFloat = 340
    /// Efficiency-core reading at which the header and the temperature row switch to the warning color.
    static let temperatureWarning = 85.0

    var onIndicatorsChanged: (([Indicator]) -> Void)?
    var onStyleChanged: ((MenuBarStyle) -> Void)?
    var onLayoutChanged: ((ModuleLayout) -> Void)?
    var onEnergyChanged: ((Bool) -> Void)?
    var onOpenClash: (() -> Void)?
    var onFanMode: ((Bool) -> Void)?
    var onFanTargets: (([Int: Double]) -> Void)?
    var onRemoveFanHelper: (() -> Void)?
    var onCheckUpdate: (() -> Void)?
    var onOpenReleases: (() -> Void)?
    var onQuit: (() -> Void)?
    /// Tallest the panel may get; the body scrolls beyond this. Set from the status item's screen before showing.
    var maximumHeight: CGFloat = 800 { didSet { if maximumHeight != oldValue { updateSize() } } }

    private let cpu = MetricRow(title: "CPU", explanation: "整机繁忙时间占比，所有核心合计。", range: 0...100, format: percentText)
    private let memory = MetricRow(title: "内存", explanation: "物理总量减去空闲和可回收缓存，包含系统物理保留区。",
                                   range: 0...100, format: percentText)
    private let temperature = MetricRow(title: "温度", explanation: "Te05、Te0S 两路能效核心传感器均值，不代表全 CPU 或热点温度。",
                                        range: nil, minimumSpan: 4, format: { String(format: "%.1f°C", $0) })
    private let download = MetricRow(title: "下载", explanation: "实体网卡流量，包含代理传输；不叠加 utun 隧道，避免重复计算。",
                                     range: nil, minimumSpan: 100 * 1024, format: { byteText($0, rate: true) })
    private let upload = MetricRow(title: "上传", explanation: "同下载，统计实体网卡发送的字节。",
                                   range: nil, minimumSpan: 100 * 1024, format: { byteText($0, rate: true) })
    private var metricRows: [MetricRow] { [cpu, memory, temperature, download, upload] }

    private var fanRows = [FanRow(0), FanRow(1)]
    private let fanRowStack = NSStackView()
    private let fanSpinner = NSProgressIndicator()
    private let fanNote = paragraph("", width: PanelViewController.width - 60)
    private let fanDraftTitle = label("目标草稿 · 待应用", size: 12, weight: .semibold)
    private let fanMode = NSSegmentedControl(labels: ["系统", "自定义"], trackingMode: .selectOne, target: nil, action: nil)
    private let fanConfirm = FillView()
    /// Section wrapper around fanConfirm; hiding the wrapper is what collapses the space.
    private var fanConfirmSlot: NSView?
    private let fanConfirmText = paragraph("", width: PanelViewController.width - 16 - RowGrid.padding * 2 - 22)
    private var fanPhase = FanPhase.reading
    private var fanReadings: [FanReading] = []
    private var fanMessage: String?
    private var confirming = false
    private let fanEditorStack = NSStackView()
    private let fanApply = NSButton(title: "应用", target: nil, action: nil)
    private var fanEditors: [Int: FanTargetEditor] = [:]
    private var editorRanges: [Int: ClosedRange<Double>] = [:]
    private static let targetPreferenceKey = "fanTargetRPM"

    private let proxyDot = StatusDot(diameter: 8, frameSize: 14)
    private let proxyNode = label("正在检查 Clash", size: 13, weight: .medium)
    private let proxyDetail = label("读取本机控制接口", size: 11, color: .secondaryLabelColor)
    private var proxyState = ProxyState.checking

    private let chip = StatusChip()
    private let titleLabel = label("StateLite", size: 14, weight: .semibold)
    private let backButton = NSButton()
    private let settingsButton = NSButton()
    private let footerText = label("", size: 11, color: .secondaryLabelColor)
    private var footerFlash: (text: String, until: Date)?
    private let scroll = NSScrollView()
    private let document = FlippedView()
    private var documentStack = NSStackView()
    private var bodyHeight: NSLayoutConstraint!
    private let header = NSView(), footer = HairlineView()
    private var sections: [PanelModuleID: ModuleSection] = [:]
    private let mainBody = NSStackView()
    private var settingsBody: NSStackView?
    private var showingSettings = false

    private var indicators = DisplayPreferences.load()
    private var style = DisplayPreferences.loadStyle()
    private var layout = DisplayPreferences.loadLayout()
    private var energySaving = true
    private var cadenceText = ""
    private var latest: (SystemMetrics, TemperatureReading)?
    private let preview = NSImageView()
    private let previewText = label("", size: 12.5, weight: .medium, monospacedDigits: true)
    private var picks: [Indicator: PillButton] = [:]
    private let styleControl = NSSegmentedControl(labels: ["并排", "上下堆叠"], trackingMode: .selectOne, target: nil, action: nil)
    private let helperStatus = paragraph("正在检查安装状态", width: PanelViewController.width - 28)
    private let updateStatus = paragraph("仅在点击时连接 GitHub，不自动下载或安装。", width: PanelViewController.width - 28)
    private let updateCheck = NSButton(title: "检查更新", target: nil, action: nil)
    private let updateOpen = NSButton(title: "发布页", target: nil, action: nil)
    private let helperRemove = NSButton(title: "卸载助手", target: nil, action: nil)
    private let helperCancel = NSButton(title: "取消", target: nil, action: nil)
    private var helperInstalled = false
    private var helperStatusText = "正在检查安装状态"
    private var helperRemovalConfirming = false
    private var helperRemovalPending = false
    private let energySwitch = NSSwitch()
    private let energyDetail = label("", size: 10.5, color: .secondaryLabelColor)
    private var moduleRows: [PanelModuleID: (up: NSButton, down: NSButton, toggle: NSSwitch)] = [:]
    private let moduleList = NSStackView()

    // MARK: Building

    override func loadView() {
        let effect = NSVisualEffectView()
        effect.material = .popover; effect.blendingMode = .behindWindow; effect.state = .active
        view = effect
        buildHeader(); buildFooter(); buildMain()
        scroll.drawsBackground = false; scroll.hasVerticalScroller = false; scroll.scrollerStyle = .overlay
        scroll.autohidesScrollers = true; scroll.borderType = .noBorder
        scroll.documentView = document
        attach(mainBody)
        let root = vertical([header, scroll, footer], spacing: 0)
        pin(root, in: view)
        bodyHeight = scroll.heightAnchor.constraint(equalToConstant: 400)
        NSLayoutConstraint.activate([
            view.widthAnchor.constraint(equalToConstant: Self.width), bodyHeight,
            header.widthAnchor.constraint(equalTo: root.widthAnchor),
            scroll.widthAnchor.constraint(equalTo: root.widthAnchor),
            footer.widthAnchor.constraint(equalTo: root.widthAnchor)
        ])
        for row in metricRows {
            row.onToggle = { [weak self, weak row] in if let row { self?.toggle(row) } }
        }
        applyLayout(); renderFanState(); refreshChip(); refreshFooter()
        updateSize()
    }

    private func iconButton(_ button: NSButton, symbol: String, label text: String, action: Selector) {
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: text)?
            .withSymbolConfiguration(.init(pointSize: 13, weight: .regular))
        button.imagePosition = .imageOnly; button.bezelStyle = .accessoryBarAction
        button.showsBorderOnlyWhileMouseInside = true; button.contentTintColor = .secondaryLabelColor
        button.target = self; button.action = action; button.toolTip = text
        button.widthAnchor.constraint(equalToConstant: 26).isActive = true
        button.heightAnchor.constraint(equalToConstant: 24).isActive = true
    }

    private func buildHeader() {
        iconButton(backButton, symbol: "chevron.left", label: "返回面板", action: #selector(backClicked))
        iconButton(settingsButton, symbol: "gearshape", label: "设置", action: #selector(settingsClicked))
        backButton.isHidden = true
        let row = horizontal([backButton, titleLabel, chip, spacer(), settingsButton], spacing: 8)
        row.setCustomSpacing(2, after: backButton)
        pin(row, in: header, NSEdgeInsets(top: 7, left: 14, bottom: 6, right: 10))
    }

    private func buildFooter() {
        let quit = NSButton(title: "退出", target: self, action: #selector(quitClicked))
        quit.bezelStyle = .accessoryBarAction; quit.showsBorderOnlyWhileMouseInside = true
        quit.font = .systemFont(ofSize: 11); quit.contentTintColor = .secondaryLabelColor
        footerText.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        pin(horizontal([footerText, spacer(), quit], spacing: 8), in: footer, NSEdgeInsets(top: 5, left: 14, bottom: 6, right: 8))
    }

    private func buildMain() {
        mainBody.orientation = .vertical; mainBody.alignment = .leading; mainBody.spacing = 0
        let system = ModuleSection(title: PanelModuleID.system.title)
        system.add(cpu); system.add(memory)

        let thermal = ModuleSection(title: PanelModuleID.thermal.title)
        thermal.add(temperature)
        fanRowStack.orientation = .vertical; fanRowStack.spacing = 0
        for row in fanRows { fanRowStack.addArrangedSubview(row); row.widthAnchor.constraint(equalTo: fanRowStack.widthAnchor).isActive = true }
        thermal.add(fanRowStack)
        fanSpinner.style = .spinning; fanSpinner.controlSize = .mini; fanSpinner.isDisplayedWhenStopped = false
        fanNote.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        thermal.add(horizontal([fanSpinner, fanNote], spacing: 5), inset: RowGrid.padding, spacingBefore: 4)
        fanMode.target = self; fanMode.action = #selector(fanModeChanged)
        fanMode.segmentDistribution = .fillEqually
        fanMode.setToolTip("交还 macOS 自动调速", forSegment: 0)
        fanMode.setToolTip("首次应用需授权安装助手，同一版本以后无需重复授权", forSegment: 1)
        thermal.add(fanMode, inset: RowGrid.padding, spacingBefore: 5)
        buildFanConfirm()
        fanConfirmSlot = thermal.add(fanConfirm, inset: RowGrid.padding, spacingBefore: 8)
        fanConfirmSlot?.isHidden = true

        let network = ModuleSection(title: PanelModuleID.network.title)
        network.add(download); network.add(upload)

        let proxy = ModuleSection(title: PanelModuleID.proxy.title)
        let open = NSButton(title: "打开 Clash ↗", target: self, action: #selector(clashClicked))
        open.controlSize = .small; open.font = .systemFont(ofSize: 11.5)
        open.toolTip = "只打开应用，不切换代理、节点或模式"
        open.setContentCompressionResistancePriority(.required, for: .horizontal)
        let texts = vertical([proxyNode, proxyDetail], spacing: 1)
        for field in [proxyNode, proxyDetail] { field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal) }
        let row = horizontal([proxyDot, texts, spacer(), open], spacing: 8)
        row.edgeInsets = NSEdgeInsets(top: 4, left: 0, bottom: 2, right: 0)
        proxy.add(row, inset: RowGrid.padding - 3)
        sections = [.system: system, .thermal: thermal, .network: network, .proxy: proxy]
    }

    private func buildFanConfirm() {
        fanConfirm.radius = 9
        fanConfirm.fill = Palette.fill(); fanConfirm.stroke = NSColor.separatorColor
        let cancel = NSButton(title: "取消", target: self, action: #selector(confirmCancelled))
        fanApply.target = self; fanApply.action = #selector(confirmAccepted)
        for button in [cancel, fanApply] { button.controlSize = .small; button.font = .systemFont(ofSize: 11.5) }
        fanApply.keyEquivalent = "\r"; cancel.keyEquivalent = "\u{1b}"
        fanEditorStack.orientation = .vertical; fanEditorStack.alignment = .leading; fanEditorStack.spacing = 7
        let buttons = horizontal([spacer(), cancel, fanApply], spacing: 6)
        let stack = vertical([fanDraftTitle, fanEditorStack, fanConfirmText, buttons], spacing: 6)
        pin(stack, in: fanConfirm, NSEdgeInsets(top: 8, left: 10, bottom: 8, right: 10))
        for row in [fanEditorStack, buttons] { row.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true }
    }

    private var validFanRanges: [Int: ClosedRange<Double>] {
        guard !fanReadings.isEmpty else { return [:] }
        var ranges: [Int: ClosedRange<Double>] = [:]
        for fan in fanReadings {
            guard let low = fan.minimumRPM, let high = fan.maximumRPM,
                  low.isFinite, high.isFinite, low >= 0, ceil(low) < floor(high), high <= 16000,
                  ranges[fan.id] == nil else { return [:] }
            ranges[fan.id] = low...high
        }
        return ranges
    }

    /// Periodic RPM readings must not overwrite an uncommitted slider position.
    private func prepareFanEditors(reset: Bool = false) {
        let ranges = validFanRanges
        if reset || ranges != editorRanges {
            fanEditorStack.arrangedSubviews.forEach { fanEditorStack.removeArrangedSubview($0); $0.removeFromSuperview() }
            fanEditors.removeAll(); editorRanges = ranges
            let saved = UserDefaults.standard.dictionary(forKey: Self.targetPreferenceKey) ?? [:]
            for fan in fanReadings where ranges[fan.id] != nil {
                let range = ranges[fan.id]!
                let preference = (saved[String(fan.id)] as? NSNumber)?.doubleValue
                let current = fan.targetRPM.flatMap { $0.isFinite && range.contains($0) ? $0 : nil }
                let initial = current ?? preference.flatMap { $0.isFinite && range.contains($0) ? $0 : nil } ?? range.upperBound
                let editor = FanTargetEditor(id: fan.id, range: range, value: initial)
                fanEditors[fan.id] = editor; fanEditorStack.addArrangedSubview(editor)
                editor.widthAnchor.constraint(equalTo: fanEditorStack.widthAnchor).isActive = true
            }
        }
        let busy = fanPhase == .authorizing || fanPhase == .restoring
        fanApply.isEnabled = !busy && !ranges.isEmpty && ranges.count == fanReadings.count && onFanTargets != nil
        fanEditors.values.forEach { $0.isEnabled = !busy }
        fanDraftTitle.stringValue = fanPhase == .custom ? "目标设置 · 修改后需应用" : "目标草稿 · 待应用"
        fanConfirmText.stringValue = ranges.isEmpty
            ? "尚未读到完整的转速范围，暂不能应用。"
            : "首次应用需授权安装助手；同一版本以后无需反复授权。退出、睡眠或失联后尝试恢复系统。"
    }

    private func attach(_ stack: NSStackView) {
        document.subviews.forEach { $0.removeFromSuperview() }
        stack.translatesAutoresizingMaskIntoConstraints = false; document.addSubview(stack)
        document.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: document.leadingAnchor),
            stack.topAnchor.constraint(equalTo: document.topAnchor),
            stack.widthAnchor.constraint(equalToConstant: Self.width),
            document.widthAnchor.constraint(equalToConstant: Self.width),
            document.heightAnchor.constraint(equalTo: stack.heightAnchor)
        ])
        documentStack = stack
        document.scroll(.zero)
    }

    private func applyLayout() {
        mainBody.arrangedSubviews.forEach { mainBody.removeArrangedSubview($0); $0.removeFromSuperview() }
        for id in layout.visible {
            guard let section = sections[id] else { continue }
            mainBody.addArrangedSubview(section)
            section.widthAnchor.constraint(equalTo: mainBody.widthAnchor).isActive = true
        }
        if layout.visible.isEmpty {
            let empty = HairlineView()
            pin(label("所有模块都已隐藏，可在设置中打开。", size: 12, color: .secondaryLabelColor), in: empty,
                NSEdgeInsets(top: 16, left: 14, bottom: 16, right: 14))
            mainBody.addArrangedSubview(empty)
            empty.widthAnchor.constraint(equalTo: mainBody.widthAnchor).isActive = true
        }
        refreshChip()
    }

    // MARK: Size

    /// The panel only changes size on structural changes (expanding a row, a different fan state,
    /// switching pages), never on value updates, so it does not twitch while it is open.
    private func updateSize() {
        guard isViewLoaded, bodyHeight != nil else { return }
        documentStack.layoutSubtreeIfNeeded()
        let content = ceil(documentStack.fittingSize.height)
        let chrome = ceil(header.fittingSize.height + footer.fittingSize.height)
        let body = min(content, max(200, min(maximumHeight, 520) - chrome))
        if bodyHeight.constant != body { bodyHeight.constant = body }
        scroll.hasVerticalScroller = content > body + 0.5
        let size = NSSize(width: Self.width, height: chrome + body)
        if preferredContentSize != size { preferredContentSize = size }
    }

    private func toggle(_ row: MetricRow) {
        let open = !row.expanded
        for other in metricRows where other !== row { other.setExpanded(false) }
        row.setExpanded(open)
        updateSize()
        if open { DispatchQueue.main.async { row.scrollToVisible(row.bounds) } }
    }

    // MARK: Inputs from the app

    func setPreferences(_ items: [Indicator], style newStyle: MenuBarStyle, layout newLayout: ModuleLayout,
                        energySaving saving: Bool, cadenceText text: String) {
        loadViewIfNeeded()
        indicators = items; style = newStyle; energySaving = saving; cadenceText = text
        if newLayout != layout { layout = newLayout; applyLayout(); updateSize() }
        syncSettings(); refreshFooter()
    }

    /// Feeds the trend lines on every sample, also while the panel is closed; no layout work.
    /// Pass nil temperature when it was not re-read this tick, so stale values aren't plotted.
    func record(_ metrics: SystemMetrics, temperature temp: TemperatureReading?) {
        loadViewIfNeeded()
        cpu.trend.append(metrics.cpuPercent)
        memory.trend.append(metrics.memoryReadingAvailable ? MenuBarLabel.memoryPercent(metrics) : nil)
        temperature.trend.append(temp?.celsius)
        download.trend.append(metrics.receivedBytesPerSecond)
        upload.trend.append(metrics.sentBytesPerSecond)
    }

    func render(_ metrics: SystemMetrics, temperature temp: TemperatureReading) {
        loadViewIfNeeded()
        latest = (metrics, temp)
        cpu.show(percentText(metrics.cpuPercent), subtitle: "整机")
        let used = Double(metrics.memoryUsedBytes) / 1_073_741_824, total = Double(metrics.memoryTotalBytes) / 1_073_741_824
        memory.show(metrics.memoryReadingAvailable ? percentText(MenuBarLabel.memoryPercent(metrics)) : "—",
                    subtitle: metrics.memoryReadingAvailable ? String(format: "%.1f / %.0f GB", used, total) : "暂时无法读取")
        let hot = (temp.celsius ?? 0) >= Self.temperatureWarning
        temperature.show(temp.celsius.map { String(format: "%.1f°C", $0) } ?? "—", subtitle: hot ? "偏高" : "能效核心", warning: hot)
        temperature.toolTip = temp.source + "\n" + temp.detail
        download.show(metrics.receivedBytesPerSecond.map { byteText($0, rate: true) } ?? "—", subtitle: "含代理流量")
        upload.show(metrics.sentBytesPerSecond.map { byteText($0, rate: true) } ?? "—", subtitle: "含代理流量")
        let interfaces = metrics.networkInterfaces.joined(separator: "、")
        for row in [download, upload] { row.toolTip = interfaces.isEmpty ? nil : "统计接口：" + interfaces }
        refreshFanAccessory(); refreshChip(); refreshFooter(); refreshPreview()
    }

    func renderFan(_ readings: [FanReading], phase: FanPhase, message: String?) {
        loadViewIfNeeded()
        let changed = phase != fanPhase || message != fanMessage || readings.count != fanReadings.count
        fanReadings = readings
        fanPhase = phase; fanMessage = message
        if phase != .system && phase != .custom { confirming = false }
        renderFanState()
        if changed { refreshChip(); updateSize() }
    }

    private func renderFanState() {
        // Keep the last known number of fan rows (two before the first read) so the panel
        // opens at its final size instead of growing when the first reading arrives.
        let count = fanPhase == .unavailable ? 0 : (fanReadings.isEmpty ? 2 : fanReadings.count)
        while fanRows.count < count {
            let row = FanRow(fanRows.count); fanRows.append(row)
            fanRowStack.addArrangedSubview(row); row.widthAnchor.constraint(equalTo: fanRowStack.widthAnchor).isActive = true
        }
        for (index, row) in fanRows.enumerated() {
            row.isHidden = index >= count
            let reading = index < fanReadings.count ? fanReadings[index]
                : FanReading(id: index, rpm: nil, minimumRPM: nil, maximumRPM: nil, targetRPM: nil, hardwareMode: nil)
            row.show(reading, boost: fanPhase.boosting)
        }
        let busy = fanPhase == .authorizing || fanPhase == .restoring
        busy ? fanSpinner.startAnimation(nil) : fanSpinner.stopAnimation(nil)
        fanSpinner.isHidden = !busy
        let note: String
        switch fanPhase {
        case .reading: note = "正在读取风扇"
        case .unavailable: note = fanMessage ?? "风扇暂不可读。可能是机型不支持，或接口被占用。"
        case .authorizing: note = helperInstalled ? "正在应用目标转速…" : "正在准备助手 · 首次安装需系统授权"
        case .restoring: note = "正在交还系统控制…"
        case .custom: note = fanMessage ?? "自定义控制中 · 退出后尝试交还系统"
        case .system: note = fanMessage ?? (rangeText.map { "未接管 · 范围 \($0) RPM" } ?? "StateLite 未接管风扇")
        }
        let visibleNote = Self.fanMessageSummary(note)
        if fanNote.stringValue != visibleNote { fanNote.stringValue = visibleNote }
        fanNote.toolTip = note
        fanNote.setAccessibilityHelp(note)
        fanMode.selectedSegment = fanPhase.boosting || fanPhase == .authorizing || confirming ? 1 : 0
        fanMode.isEnabled = !busy && fanPhase != .reading && fanPhase != .unavailable
        prepareFanEditors()
        fanConfirmSlot?.isHidden = !(confirming || fanPhase == .custom)
        refreshFanAccessory()
    }

    /// Keep the failure and recovery uncertainty visible; retain raw diagnostics in the tooltip.
    static func fanMessageSummary(_ message: String) -> String {
        if let marker = message.range(of: "stage=") {
            let stage = String(message[marker.upperBound...].prefix { !$0.isWhitespace })
            let reasons: [String: String] = [
                "mode_write": "未能切换手动模式",
                "mode_readback": "手动模式未确认",
                "mode_final_readback": "手动模式未保持",
                "target_write": "目标转速写入失败",
                "target_preload_readback": "目标转速未确认",
                "target_final_readback": "目标转速读回不一致",
                "unlock_Ftst": "未能请求系统交出调速控制",
                "thermalmonitord_yield_timeout": "等待系统交出控制超时",
                "transition_lease_expired": "应用时连接或会话已结束",
                "parent_identity": "助手未能验证应用进程",
                "parent_image_hash": "应用与助手版本不匹配",
                "smc_open": "无法连接风扇控制接口",
                "another_session_or_unsafe_lock": "其他会话占用控制，或锁文件异常",
                "unsupported_metadata": "未识别到可用调速接口",
                "invalid_targets_or_range": "目标超出范围或格式无效",
                "restore": "交回系统控制未确认",
                "exit_restore_failed": "助手退出前未能确认恢复"
            ]
            if stage == "restore" || stage == "exit_restore_failed" {
                return "交回系统控制未确认。\n旧目标可能仍在生效，请检查实际转速。"
            }
            return "应用未确认：" + (reasons[stage] ?? "助手操作失败") + "。\n恢复状态未确认，请查看实际转速。"
        }
        if message.contains("请求超时") || message.contains("助手连接结束") || message.contains("调速未确认") {
            return "应用未确认：助手未确认此次设置。\n恢复状态未确认，请查看实际转速。"
        }
        if message.contains("授权启动失败") {
            return "未应用：管理员助手启动失败。\n将鼠标停在此处查看完整错误码。"
        }
        return message
    }

    private var rangeText: String? {
        let lows = fanReadings.compactMap(\.minimumRPM), highs = fanReadings.compactMap(\.maximumRPM)
        guard let low = lows.min(), let high = highs.max(), high > 0 else { return nil }
        return rpmText(low) + "–" + rpmText(high)
    }

    private func refreshFanAccessory() {
        guard let section = sections[.thermal] else { return }
        var text = "", color = NSColor.secondaryLabelColor
        switch fanPhase {
        case .reading: text = ""
        case .unavailable: text = "风扇不可读"
        case .system: text = confirming ? "草稿未应用" : "未接管"
        case .authorizing: text = "正在应用"
        case .restoring: text = "正在交还"
        case .custom:
            text = "自定义"; color = Palette.warn
        }
        if section.accessory.stringValue != text { section.accessory.stringValue = text }
        section.accessory.textColor = color
        section.accessory.font = .monospacedDigitSystemFont(ofSize: 11, weight: fanPhase.boosting ? .semibold : .regular)
    }

    func renderProxy(_ state: ProxyState, node: String, detail: String) {
        loadViewIfNeeded()
        proxyState = state
        if proxyNode.stringValue != node { proxyNode.stringValue = node }
        if proxyDetail.stringValue != detail { proxyDetail.stringValue = detail }
        proxyNode.toolTip = node; proxyDetail.toolTip = detail
        switch state {
        case .checking, .notRunning: proxyDot.color = .tertiaryLabelColor; proxyDot.halo = false
        case .connected: proxyDot.color = Palette.ok; proxyDot.halo = true
        case .degraded: proxyDot.color = Palette.warn; proxyDot.halo = false
        }
        refreshChip()
    }

    /// Transient footer message, e.g. the result of a button press.
    func flash(_ text: String) {
        loadViewIfNeeded()
        footerFlash = (text, Date().addingTimeInterval(3)); refreshFooter()
    }

    private func refreshFooter() {
        let flashing = footerFlash.map { Date() < $0.until } ?? false
        let text = showingSettings ? "StateLite 0.3 · 仅本机读取" : flashing ? footerFlash!.text : cadenceText
        if footerText.stringValue != text { footerText.stringValue = text }
        footerText.textColor = flashing && !showingSettings ? .labelColor : .secondaryLabelColor
    }

    /// The most important state wins: heat, then a fan override, then a missing proxy.
    private func refreshChip() {
        let celsius = latest?.1.celsius ?? 0
        if celsius >= Self.temperatureWarning { chip.show(.warn, "温度偏高") }
        else if fanPhase.boosting { chip.show(.warn, "风扇自定义") }
        else if layout.visible.contains(.proxy) && (proxyState == .degraded || proxyState == .notRunning) { chip.show(.neutral, "代理未连接") }
        else { chip.show(.ok, "运行平稳") }
    }

    // MARK: Settings page

    private func buildSettings() -> NSStackView {
        let width = Self.width - 28
        let previewStrip = FillView()
        previewStrip.radius = 7; previewStrip.fill = NSColor.windowBackgroundColor.withAlphaComponent(0.7)
        previewStrip.stroke = NSColor.separatorColor
        previewText.alignment = .right
        let previewRow = horizontal([spacer(), previewText, preview], spacing: 0)
        pin(previewRow, in: previewStrip, NSEdgeInsets(top: 0, left: 10, bottom: 0, right: 10))
        previewStrip.heightAnchor.constraint(equalToConstant: 30).isActive = true
        previewStrip.setAccessibilityElement(true); previewStrip.setAccessibilityRole(.staticText)

        for item in Indicator.allCases {
            let pill = PillButton(item.title)
            pill.onClick = { [weak self] in self?.pick(item) }
            picks[item] = pill
        }
        let all = Indicator.allCases.compactMap { picks[$0] }
        let pickRows = vertical([horizontal(Array(all.prefix(3)), spacing: 6), horizontal(Array(all.dropFirst(3)), spacing: 6)], spacing: 6)
        styleControl.target = self; styleControl.action = #selector(styleChanged); styleControl.segmentDistribution = .fillEqually
        let menuBar = group("菜单栏", [previewStrip, pickRows,
                                       paragraph("最多两项，按点选顺序排列。再点一次取消。", width: width), styleControl], spacing: 8)
        previewStrip.widthAnchor.constraint(equalToConstant: width).isActive = true
        styleControl.widthAnchor.constraint(equalToConstant: width).isActive = true

        moduleList.orientation = .vertical; moduleList.spacing = 0; moduleList.alignment = .leading
        for id in PanelModuleID.allCases {
            let up = NSButton(), down = NSButton(), toggle = NSSwitch()
            for (button, symbol, verb) in [(up, "chevron.up", "上移"), (down, "chevron.down", "下移")] {
                button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: id.title + verb)?
                    .withSymbolConfiguration(.init(pointSize: 10, weight: .semibold))
                button.bezelStyle = .accessoryBarAction; button.showsBorderOnlyWhileMouseInside = true
                button.imagePosition = .imageOnly; button.contentTintColor = .secondaryLabelColor
                button.target = self; button.identifier = NSUserInterfaceItemIdentifier(id.rawValue)
                button.widthAnchor.constraint(equalToConstant: 22).isActive = true
            }
            up.action = #selector(moveModuleUp(_:)); down.action = #selector(moveModuleDown(_:))
            toggle.controlSize = .mini; toggle.target = self; toggle.action = #selector(moduleToggled(_:))
            toggle.identifier = NSUserInterfaceItemIdentifier(id.rawValue)
            toggle.setAccessibilityLabel("显示" + id.title)
            moduleRows[id] = (up, down, toggle)
        }
        let reserved = listRow(title: "电池 · 磁盘 · GPU 功耗", detail: label("预留位置，尚未实现", size: 10.5, color: .tertiaryLabelColor),
                               trailing: [], muted: true)
        let modulesBox = NSStackView(views: [moduleList, reserved])
        modulesBox.orientation = .vertical; modulesBox.spacing = 0
        for view in [moduleList, reserved] { view.widthAnchor.constraint(equalTo: modulesBox.widthAnchor).isActive = true }
        let modules = group("面板模块", [listBox(modulesBox)])

        energySwitch.controlSize = .mini; energySwitch.target = self; energySwitch.action = #selector(energyClicked)
        energySwitch.setAccessibilityLabel("节能刷新")
        let energyRow = listRow(title: "节能刷新", detail: energyDetail, trailing: [energySwitch], first: true)
        let refreshList = NSStackView(views: [energyRow]); refreshList.orientation = .vertical
        energyRow.widthAnchor.constraint(equalTo: refreshList.widthAnchor).isActive = true
        let refresh = group("刷新", [listBox(refreshList),
                                    paragraph("面板打开时指标每 1 秒、温度每 5 秒刷新；低电量模式下减半。", width: width)])

        helperRemove.target = self; helperRemove.action = #selector(removeFanHelperClicked)
        helperCancel.target = self; helperCancel.action = #selector(cancelFanHelperRemoval)
        for button in [helperRemove, helperCancel] { button.controlSize = .small; button.font = .systemFont(ofSize: 11.5) }
        let helperButtons = horizontal([spacer(), helperCancel, helperRemove], spacing: 6)
        let helper = group("风扇助手", [helperStatus, helperButtons,
            paragraph("首次安装授权一次；同一版本跨重启可继续使用。应用升级时可能需要重新授权。", width: width)], spacing: 6)
        helperButtons.widthAnchor.constraint(equalTo: helper.widthAnchor).isActive = true
        refreshFanHelperStatus()

        updateCheck.target = self; updateCheck.action = #selector(checkUpdateClicked)
        updateOpen.target = self; updateOpen.action = #selector(openReleasesClicked)
        for button in [updateCheck, updateOpen] { button.controlSize = .small; button.font = .systemFont(ofSize: 11.5) }
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "未知"
        let updates = group("版本与更新 · " + version, [updateStatus, horizontal([spacer(), updateOpen, updateCheck], spacing: 6)])

        let about = group("说明", [
            paragraph("所有监控读数都在本机读取；手动检查更新会连接 GitHub。内存包含系统物理保留区；网络统计实体网卡，代理流量不会重复相加。", width: width),
            paragraph("Clash 只读取策略组和节点，不切换代理、节点或模式。自定义转速由本机助手按需执行，退出、睡眠或失联后尝试恢复系统控制；固定转速不等同于自动温控。", width: width)
        ], spacing: 6)

        let stack = vertical([menuBar, modules, refresh, helper, updates, about], spacing: 16)
        stack.edgeInsets = NSEdgeInsets(top: 6, left: 14, bottom: 14, right: 14)
        for view in [menuBar, modules, refresh, helper, updates, about] { view.widthAnchor.constraint(equalToConstant: width).isActive = true }
        return stack
    }

    func setUpdateStatus(_ text: String, checking: Bool) {
        updateStatus.stringValue = text; updateCheck.isEnabled = !checking
        if showingSettings { updateSize() }
    }
    @objc private func checkUpdateClicked() { onCheckUpdate?() }
    @objc private func openReleasesClicked() { onOpenReleases?() }

    private func group(_ title: String, _ views: [NSView], spacing: CGFloat = 7) -> NSStackView {
        let stack = vertical([sectionTitle(title)] + views, spacing: spacing)
        for view in views where view is FillView || view is NSSegmentedControl {
            view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        return stack
    }

    private func listBox(_ list: NSStackView) -> FillView {
        let box = FillView(); box.fill = Palette.fill(); box.radius = 9
        pin(list, in: box)
        return box
    }

    private func listRow(title: String, detail: NSTextField, trailing: [NSView], first: Bool = false, muted: Bool = false) -> NSView {
        let row = HairlineView(); row.showsLine = !first
        let name = label(title, size: 12.5, color: muted ? .tertiaryLabelColor : .labelColor)
        let texts = vertical([name, detail], spacing: 1)
        texts.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let content = horizontal([texts, spacer()] + trailing, spacing: 4)
        pin(content, in: row, NSEdgeInsets(top: 6, left: 11, bottom: 6, right: 9))
        row.heightAnchor.constraint(greaterThanOrEqualToConstant: 38).isActive = true
        return row
    }

    private func rebuildModuleList() {
        moduleList.arrangedSubviews.forEach { moduleList.removeArrangedSubview($0); $0.removeFromSuperview() }
        for (index, id) in layout.order.enumerated() {
            guard let controls = moduleRows[id] else { continue }
            [controls.up, controls.down, controls.toggle].forEach { $0.removeFromSuperview() }
            let row = listRow(title: id.title, detail: label(id.summary, size: 10.5, color: .secondaryLabelColor),
                              trailing: [controls.up, controls.down, controls.toggle], first: index == 0)
            moduleList.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: moduleList.widthAnchor).isActive = true
            controls.up.isEnabled = index > 0; controls.down.isEnabled = index < layout.order.count - 1
            controls.toggle.state = layout.hidden.contains(id) ? .off : .on
        }
    }

    private func syncSettings() {
        guard settingsBody != nil else { return }
        for (item, pill) in picks { pill.order = indicators.firstIndex(of: item).map { $0 + 1 } }
        styleControl.selectedSegment = style == .stacked ? 1 : 0
        energySwitch.state = energySaving ? .on : .off
        energyDetail.stringValue = energySaving ? "面板关闭时指标每 5 秒、温度每 15 秒" : "面板关闭时指标每 2 秒、温度每 15 秒"
        rebuildModuleList(); refreshPreview()
    }

    private func refreshPreview() {
        guard settingsBody != nil, let (metrics, temp) = latest else { return }
        let parts = MenuBarLabel.parts(indicators, metrics: metrics, temperature: temp)
        let stacked = style == .stacked && parts.count > 1
        preview.isHidden = !stacked; previewText.isHidden = stacked
        if stacked {
            preview.image = MenuBarLabel.stacked(parts, height: 24, color: .labelColor)
        } else if previewText.stringValue != MenuBarLabel.inline(parts) {
            previewText.stringValue = MenuBarLabel.inline(parts)
        }
        preview.superview?.superview?.setAccessibilityLabel("菜单栏预览：" + MenuBarLabel.inline(parts))
    }

    private func showSettings(_ on: Bool) {
        if on && settingsBody == nil { settingsBody = buildSettings() }
        showingSettings = on
        if !on { helperRemovalConfirming = false; refreshFanHelperStatus() }
        for row in metricRows { row.setExpanded(false) }
        attach(on ? settingsBody! : mainBody)
        if on { syncSettings() }
        backButton.isHidden = !on; settingsButton.isHidden = on; chip.isHidden = on
        titleLabel.stringValue = on ? "设置" : "StateLite"
        refreshFooter(); updateSize()
        if NSApp.currentEvent?.type == .keyDown {
            view.window?.makeFirstResponder(on ? backButton : settingsButton)
        } else { view.window?.makeFirstResponder(nil) }
    }

    /// Closing the panel returns to the readings next time.
    func panelDidClose() {
        if showingSettings { showSettings(false) }
        for row in metricRows { row.setExpanded(false) }
        if confirming { confirming = false; renderFanState() }
        document.scroll(.zero)
        updateSize()
    }

    /// Main owns installation checks, restoration and removal. A status update completes a pending removal.
    func setFanHelperStatus(_ text: String, installed: Bool) {
        if text != helperStatusText || installed != helperInstalled { helperRemovalConfirming = false }
        helperStatusText = text; helperInstalled = installed; helperRemovalPending = false
        refreshFanHelperStatus()
        if isViewLoaded { renderFanState(); updateSize() }
    }

    private func refreshFanHelperStatus() {
        helperStatus.stringValue = helperRemovalPending ? "正在卸载，等待操作结果…"
            : helperRemovalConfirming ? "卸载前将尝试交回系统控制。再次点击确认卸载；以后调速需重新安装授权。"
            : helperStatusText
        helperStatus.toolTip = helperStatusText
        helperRemove.title = helperRemovalConfirming ? "确认卸载" : "卸载助手"
        helperRemove.isEnabled = helperInstalled && !helperRemovalPending && onRemoveFanHelper != nil
        helperRemove.contentTintColor = helperRemovalConfirming ? .systemRed : nil
        helperCancel.isHidden = !helperRemovalConfirming || helperRemovalPending
    }

    @objc private func removeFanHelperClicked() {
        guard helperInstalled, !helperRemovalPending, let callback = onRemoveFanHelper else { return }
        if helperRemovalConfirming {
            helperRemovalConfirming = false; helperRemovalPending = true
            refreshFanHelperStatus(); updateSize(); callback()
        } else {
            helperRemovalConfirming = true; refreshFanHelperStatus(); updateSize()
        }
    }
    @objc private func cancelFanHelperRemoval() {
        helperRemovalConfirming = false; refreshFanHelperStatus(); updateSize()
    }

    // MARK: Actions

    private func pick(_ item: Indicator) {
        var items = indicators
        if let index = items.firstIndex(of: item) { if items.count > 1 { items.remove(at: index) } }
        else { if items.count >= 2 { items.removeLast() }; items.append(item) }
        indicators = items; syncSettings(); onIndicatorsChanged?(items)
    }
    @objc private func styleChanged() {
        style = styleControl.selectedSegment == 1 ? .stacked : .inline
        refreshPreview(); onStyleChanged?(style)
    }
    @objc private func moveModuleUp(_ sender: NSButton) { move(sender, by: -1) }
    @objc private func moveModuleDown(_ sender: NSButton) { move(sender, by: 1) }
    private func move(_ sender: NSButton, by offset: Int) {
        guard let raw = sender.identifier?.rawValue, let id = PanelModuleID(rawValue: raw),
              let index = layout.order.firstIndex(of: id), layout.order.indices.contains(index + offset) else { return }
        layout.order.swapAt(index, index + offset)
        changedLayout()
        // Keep keyboard focus on the moved module when its button is disabled at either end.
        if let controls = moduleRows[id] {
            let target = offset < 0 ? controls.up : controls.down
            view.window?.makeFirstResponder(target.isEnabled ? target : controls.toggle)
        }
    }
    @objc private func moduleToggled(_ sender: NSSwitch) {
        guard let raw = sender.identifier?.rawValue, let id = PanelModuleID(rawValue: raw) else { return }
        if sender.state == .on { layout.hidden.remove(id) } else { layout.hidden.insert(id) }
        changedLayout()
    }
    private func changedLayout() {
        applyLayout(); rebuildModuleList(); onLayoutChanged?(layout)
    }
    @objc private func energyClicked() { onEnergyChanged?(energySwitch.state == .on) }
    @objc private func settingsClicked() { showSettings(true) }
    @objc private func backClicked() { showSettings(false) }
    @objc private func clashClicked() { onOpenClash?() }
    @objc private func quitClicked() { onQuit?() }
    @objc private func fanModeChanged() {
        if fanMode.selectedSegment == 1 {
            confirming = true; prepareFanEditors(reset: true)
        } else {
            confirming = false
            if fanPhase == .custom { onFanMode?(false) }
        }
        renderFanState(); updateSize()
    }
    @objc private func confirmCancelled() {
        confirming = false; prepareFanEditors(reset: true); renderFanState(); updateSize()
    }
    @objc private func confirmAccepted() {
        let ranges = validFanRanges
        guard !ranges.isEmpty, ranges == editorRanges, fanEditors.count == fanReadings.count,
              fanPhase == .system || fanPhase == .custom, let callback = onFanTargets else { return }
        let targets = fanEditors.mapValues { $0.value }
        guard targets.allSatisfy({ id, rpm in rpm.isFinite && ranges[id]?.contains(rpm) == true }) else { return }
        UserDefaults.standard.set(Dictionary(uniqueKeysWithValues: targets.map { (String($0.key), $0.value) }),
                                  forKey: Self.targetPreferenceKey)
        confirming = false; callback(targets); renderFanState(); updateSize()
    }
}
