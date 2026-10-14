import AppKit

func byteText(_ bytes: Double, rate: Bool = false) -> String {
    guard bytes.isFinite, bytes >= 0 else { return "—" }
    let units = rate ? ["B/s", "KB/s", "MB/s", "GB/s"] : ["B", "KB", "MB", "GB"]
    var value = bytes, index = 0
    while value >= 1024 && index < units.count - 1 { value /= 1024; index += 1 }
    return String(format: value >= 100 || index == 0 ? "%.0f %@" : "%.1f %@", value, units[index])
}

// Local, credential-free status for troubleshooting a user-authorized fan request.
func recordFanStatus(_ message: String) {
    UserDefaults.standard.set(message, forKey: "lastFanControlStatus")
    UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: "lastFanControlStatusTime")
}

// A single coalesced timer owns kernel/SMC reads; network requests use their own async API.
final class SamplingEngine {
    private let queue = DispatchQueue(label: "local.StateLite.sampling", qos: .utility)
    private let metrics = MetricsSampler()
    private let temperature = TemperatureSampler()
    private var timer: DispatchSourceTimer?
    private var lastTemperature = TemperatureReading(celsius: nil, source: "等待采样", detail: "")
    private var lastTemperatureTime = -Double.infinity
    private var temperatureInterval = 15.0
    private var wantsTemperature = true
    /// The Bool is true only when the temperature was read on this tick rather than reused.
    var onReading: ((SystemMetrics, TemperatureReading, Bool) -> Void)?
    var onHardwareTick: (() -> Void)?
    func configure(interval: Double, temperatureInterval: Double, wantsTemperature: Bool, reset: Bool = false) {
        queue.async { [self] in
            timer?.cancel(); self.temperatureInterval = temperatureInterval
            if wantsTemperature && !self.wantsTemperature { lastTemperatureTime = -.infinity }
            self.wantsTemperature = wantsTemperature
            if reset { metrics.reset(); temperature.reset(); lastTemperatureTime = -.infinity }
            let source = DispatchSource.makeTimerSource(queue: queue)
            source.schedule(deadline: reset ? .now() : .now() + interval, repeating: interval,
                            leeway: .milliseconds(Int(interval * 200)))
            source.setEventHandler { [weak self] in self?.sample() }
            timer = source; source.resume()
        }
    }
    func pause() { queue.async { [self] in timer?.cancel(); timer = nil; metrics.reset() } }
    private func sample() {
        let now = ProcessInfo.processInfo.systemUptime
        let reading = metrics.sample()
        let fresh = wantsTemperature && now - lastTemperatureTime >= temperatureInterval
        if fresh { lastTemperature = temperature.sample(); lastTemperatureTime = now }
        let temp = lastTemperature
        DispatchQueue.main.async { [weak self] in
            self?.onReading?(reading, temp, fresh); self?.onHardwareTick?()
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate, NSWindowDelegate {
    private let engine = SamplingEngine()
    private let panel = PanelViewController()
    private let proxy = ProxyMonitor()
    private var updateURL = UpdateChecker.releasesURL
    private let fanSampler = FanSampler()
    private var fanController = FanController()
    private let fanQueue = DispatchQueue(label: "StateLite.fan-read", qos: .utility)
    private var fanSnapshot = FanSnapshot(fans: [], detail: "等待采样")
    private var lastFanRead = -Double.infinity
    private var lastProxyRead = -Double.infinity
    private var fanReadPending = false
    private var fanPhase = FanPhase.reading
    /// Shown under the fan rows in system mode; nil shows the hardware range instead.
    private var fanMessage: String?
    private let popover = NSPopover()
    private var status: NSStatusItem!
    private var preview: NSWindow?
    private var systemSleeping = false
    private var displaySleeping = false
    private var latestReading: (SystemMetrics, TemperatureReading)?
    private var indicators = DisplayPreferences.load()
    private var menuBarStyle = DisplayPreferences.loadStyle()
    private var moduleLayout = DisplayPreferences.loadLayout()
    private var notifications: [NSObjectProtocol] = []
    private var panelVisible: Bool { popover.isShown || preview?.isVisible == true }
    private var energySaving: Bool {
        get { !UserDefaults.standard.bool(forKey: "responsiveRefresh") }
        set { UserDefaults.standard.set(!newValue, forKey: "responsiveRefresh") }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        status = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        status.button?.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        status.button?.title = "CPU —"
        status.button?.toolTip = "StateLite · 打开系统监控"
        status.button?.target = self; status.button?.action = #selector(togglePanel)
        status.button?.imagePosition = .noImage
        popover.behavior = .transient; popover.delegate = self; popover.animates = true
        popover.contentViewController = panel
        panel.onIndicatorsChanged = { [weak self] items in
            guard let self else { return }
            indicators = items; DisplayPreferences.save(items); updateTitle(); schedule()
        }
        panel.onStyleChanged = { [weak self] style in
            guard let self else { return }
            menuBarStyle = style; DisplayPreferences.saveStyle(style); updateTitle()
        }
        panel.onLayoutChanged = { [weak self] layout in
            guard let self else { return }
            moduleLayout = layout; DisplayPreferences.saveLayout(layout); schedule()
        }
        panel.onEnergyChanged = { [weak self] enabled in self?.energySaving = enabled; self?.schedule() }
        panel.onQuit = { NSApp.terminate(nil) }
        panel.onOpenReleases = { [weak self] in
            guard let self else { return }; NSWorkspace.shared.open(updateURL)
        }
        panel.onCheckUpdate = { [weak self] in
            guard let self else { return }
            panel.setUpdateStatus("正在连接 GitHub…", checking: true)
            let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
            UpdateChecker.check(current: version) { [weak self] result in
                guard let self else { return }
                updateURL = UpdateChecker.releasesURL
                if case .available(_, let url) = result { updateURL = url }
                panel.setUpdateStatus(result.message, checking: false)
            }
        }
        configureIntegrations()
        engine.onReading = { [weak self] metrics, temp, freshTemperature in
            guard let self else { return }
            latestReading = (metrics, temp); updateTitle()
            panel.record(metrics, temperature: freshTemperature ? temp : nil)
            if panelVisible { panel.render(metrics, temperature: temp) }
        }
        engine.onHardwareTick = { [weak self] in self?.refreshIntegrations() }
        let workspace = NSWorkspace.shared.notificationCenter
        notifications.append(workspace.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            self?.systemSleeping = true; self?.restoreFans(); self?.schedule()
        })
        notifications.append(workspace.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            self?.systemSleeping = false; self?.schedule(reset: true)
        })
        notifications.append(workspace.addObserver(forName: NSWorkspace.screensDidSleepNotification, object: nil, queue: .main) { [weak self] _ in
            self?.displaySleeping = true; self?.restoreFans(); self?.schedule()
        })
        notifications.append(workspace.addObserver(forName: NSWorkspace.screensDidWakeNotification, object: nil, queue: .main) { [weak self] _ in
            self?.displaySleeping = false; self?.schedule(reset: true)
        })
        notifications.append(NotificationCenter.default.addObserver(forName: .NSProcessInfoPowerStateDidChange, object: nil, queue: .main) { [weak self] _ in self?.schedule() })
        if CommandLine.arguments.contains("--preview") {
            let window = NSWindow(contentViewController: panel)
            window.title = "StateLite"; window.styleMask = [.titled, .closable]
            // --appearance=dark|light pins the look for visual checks of both themes.
            if let value = CommandLine.arguments.first(where: { $0.hasPrefix("--appearance=") })?.dropFirst(13) {
                NSApp.appearance = NSAppearance(named: value == "dark" ? .darkAqua : .aqua)
            }
            window.delegate = self; window.center(); window.makeKeyAndOrderFront(nil)
            // Follow the panel's size, as the popover does.
            panelSizeObservation = panel.observe(\.preferredContentSize, options: [.new]) { [weak window] panel, _ in
                DispatchQueue.main.async { window?.setContentSize(panel.preferredContentSize) }
            }
            NSApp.activate(ignoringOtherApps: true); preview = window
        }
        schedule(reset: true)
        if CommandLine.arguments.contains("--show-panel") { DispatchQueue.main.async { [weak self] in self?.togglePanel() } }
    }
    private var panelSizeObservation: NSKeyValueObservation?
    @objc private func togglePanel() {
        guard let button = status.button else { return }
        if popover.isShown { popover.performClose(nil) } else {
            panel.maximumHeight = maximumPanelHeight(for: button.window?.screen)
            if let (metrics, temp) = latestReading { panel.render(metrics, temperature: temp) }
            renderFan()
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            NSApp.activate(ignoringOtherApps: true)
        }
    }
    /// The popover never grows past the screen it opens on: below the menu bar, above the Dock,
    /// with room for the popover arrow and a margin. Beyond that the panel body scrolls.
    private func maximumPanelHeight(for screen: NSScreen?) -> CGFloat {
        guard let screen = screen ?? NSScreen.main else { return 720 }
        return max(320, screen.visibleFrame.height - 28)
    }
    func popoverDidShow(_ notification: Notification) { schedule(); refreshIntegrations(force: true) }
    func popoverDidClose(_ notification: Notification) { panel.panelDidClose(); schedule() }
    func windowWillClose(_ notification: Notification) { if preview != nil { NSApp.terminate(nil) } }
    private func schedule(reset: Bool = false) {
        if systemSleeping || displaySleeping { engine.pause(); return }
        let lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
        let interval: Double = panelVisible ? (lowPower ? 2 : 1) : (energySaving ? (lowPower ? 10 : 5) : (lowPower ? 5 : 2))
        let tempInterval: Double = panelVisible ? 5 : (lowPower ? 30 : 15)
        panel.setPreferences(indicators, style: menuBarStyle, layout: moduleLayout, energySaving: energySaving,
                             cadenceText: "每 \(Int(interval)) 秒刷新 · 温度每 \(Int(tempInterval)) 秒 · 仅本机读取")
        engine.configure(interval: interval, temperatureInterval: tempInterval,
                         wantsTemperature: panelVisible || indicators.contains(.temperature), reset: reset)
    }
    private func updateTitle() {
        guard let (metrics, temp) = latestReading, let button = status.button else { return }
        let parts = MenuBarLabel.parts(indicators, metrics: metrics, temperature: temp)
        let text = MenuBarLabel.inline(parts)
        if menuBarStyle == .stacked && parts.count > 1 {
            if !button.title.isEmpty { button.title = "" }
            button.imagePosition = .imageOnly
            button.image = MenuBarLabel.stacked(parts, height: NSStatusBar.system.thickness)
        } else {
            if button.image != nil { button.image = nil }
            button.imagePosition = .noImage
            if button.title != text { button.title = text }
        }
        button.setAccessibilityLabel("StateLite " + text)
    }
    // Integration implementations are below; all view mutation remains on main.
    private func configureIntegrations() {
        updateFanHelperStatus()
        // Helper-originated changes: boost confirmed, lease expiry, connection loss.
        fanController.onStateChange = { [weak self] boosted, message in
            recordFanStatus(message)
            guard let self else { return }
            if boosted {
                setFanPhase(.custom)
            } else {
                fanMessage = message
                setFanPhase(.system)
            }
        }
        panel.onOpenClash = { [weak self] in
            self?.proxy.openClash { [weak self] success in
                guard let self else { return }
                if success { panel.flash("已打开 Clash Verge"); lastProxyRead = -.infinity; refreshProxy() } else {
                    panel.renderProxy(.notRunning, node: "未找到 Clash Verge", detail: "请先安装或手动打开 Clash Verge")
                }
            }
        }
        panel.onFanTargets = { [weak self] targets in
            guard let self else { return }
            fanMessage = nil; setFanPhase(.authorizing)
            fanController.setTargets(targets) { [weak self] result in
                guard let self else { return }
                switch result {
                case .success: setFanPhase(.custom)
                case .failure(let error): recordFanStatus(error.message); fanMessage = error.message; setFanPhase(.system)
                }
                lastFanRead = -.infinity; refreshIntegrations()
                updateFanHelperStatus()
            }
        }
        panel.onFanMode = { [weak self] _ in
            guard let self else { return }
            guard fanController.boostActive else { renderFan(); return }
            fanMessage = nil; setFanPhase(.restoring)
            fanController.restoreSystemControl { [weak self] result in
                guard let self else { return }
                switch result {
                case .success: fanMessage = "助手已确认交还系统控制"
                case .failure(let error): recordFanStatus(error.message); fanMessage = error.message
                }
                setFanPhase(.system)
                lastFanRead = -.infinity; refreshIntegrations()
            }
        }
        panel.onRemoveFanHelper = { [weak self] in
            guard let self else { return }
            fanMessage = "正在恢复系统并卸载助手"; setFanPhase(.restoring)
            fanController.uninstall { [weak self] result in
                guard let self else { return }
                switch result {
                case .success: fanMessage = "调速助手已卸载"
                case .failure(let error): fanMessage = error.message
                }
                recordFanStatus(fanMessage ?? "")
                fanController = FanController(); configureIntegrations()
                setFanPhase(.system)
            }
        }
    }
    private func updateFanHelperStatus() {
        let state = fanController.installationState
        panel.setFanHelperStatus(fanController.installationDescription, installed: state == 0 || state == 2)
    }
    private func setFanPhase(_ phase: FanPhase) {
        fanPhase = phase
        renderFan()
    }
    private func refreshProxy() {
        let local = proxy.sample()
        proxy.refreshController { [weak self] result in
            guard let self, panelVisible else { return }
            let selection = result.selections.first
            let mode = result.mode == "rule" ? "规则模式" : result.mode == "global" ? "全局模式" : result.mode == "direct" ? "直连模式" : nil
            let systemProxy = "系统代理\(local.systemProxyEnabled ? "已开启" : "未开启")"
            if result.available {
                panel.renderProxy(.connected, node: selection?.resolvedNode ?? result.status,
                                  detail: ([selection?.group, mode, systemProxy].compactMap { $0 }).joined(separator: " · "))
            } else if !local.clashRunning {
                panel.renderProxy(.notRunning, node: "Clash Verge 未运行", detail: "打开后自动读取当前节点 · " + systemProxy)
            } else {
                panel.renderProxy(.degraded, node: "节点暂不可读", detail: result.status + " · 15 秒后重试")
            }
        }
    }
    private func refreshIntegrations(force: Bool = false) {
        guard panelVisible else { return }
        let now = ProcessInfo.processInfo.systemUptime
        if force || now - lastProxyRead >= 15 { lastProxyRead = now; refreshProxy() }
        if !fanReadPending && (force || now - lastFanRead >= 5) {
            fanReadPending = true; lastFanRead = now
            fanQueue.async { [weak self] in
                guard let self else { return }
                let reading = fanSampler.sample()
                DispatchQueue.main.async { [weak self] in
                    self?.fanReadPending = false; self?.fanSnapshot = reading; self?.renderFan()
                }
            }
        }
    }
    private func renderFan() {
        guard panelVisible else { return }
        // A read that finds no fans only marks the module unavailable while StateLite is not controlling them.
        var phase = fanPhase
        if phase == .reading || phase == .system || phase == .unavailable {
            phase = fanSnapshot.fans.isEmpty ? (lastFanRead.isFinite ? .unavailable : .reading) : .system
            if phase != fanPhase { fanPhase = phase }
        }
        panel.renderFan(fanSnapshot.fans, phase: phase,
                        message: phase == .unavailable ? fanSnapshot.detail : fanMessage)
    }
    private func restoreFans() {
        fanController.shutdown()
        fanController = FanController()
        configureIntegrations()
        if fanPhase.boosting || fanPhase == .authorizing || fanPhase == .restoring {
            fanMessage = "已结束自定义会话；助手将尝试恢复系统控制"
        }
        fanPhase = fanSnapshot.fans.isEmpty ? .reading : .system
        fanQueue.async { [weak self] in self?.fanSampler.reset() }
    }
    func applicationWillTerminate(_ notification: Notification) { restoreFans(); engine.pause() }
}

// Explicit, bounded local acceptance run. Uses the same signed client and lease as the UI.
// Targets never exceed 3500 RPM unless a fan's reported hardware minimum is higher.
final class FanAcceptanceRun {
    private let controller = FanController()
    private let sampler = FanSampler()
    private var finished = false
    private var code: Int32 = 1
    private var targets: [Int: Double] = [:]
    private var stableSamples = 0
    private var samples = 0
    private var absoluteWatchdog: DispatchWorkItem?
    private var activeWatchdog: DispatchWorkItem?
    private func watchdog(after seconds: Double) -> DispatchWorkItem {
        let work = DispatchWorkItem { [controller] in
            controller.shutdown()
            let text = "Fan verification watchdog expired; recovery requested, not confirmed.\n"
            text.withCString { _ = write(STDERR_FILENO, $0, strlen($0)) }
            _exit(124)
        }
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + seconds, execute: work)
        return work
    }
    private func emit(_ event: String, _ detail: String = "", fans: [FanReading]? = nil) {
        let fans = fans ?? sampler.sample().fans
        let rows: [[String: Any]] = fans.map { ["id": $0.id, "rpm": $0.rpm as Any? ?? NSNull(),
            "target": $0.targetRPM as Any? ?? NSNull(), "mode": $0.hardwareMode as Any? ?? NSNull()] }
        let value: [String: Any] = ["event": event, "detail": detail, "fans": rows,
            "requestedTargets": Dictionary(uniqueKeysWithValues: targets.map { (String($0.key), $0.value) })]
        if let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]), let line = String(data: data, encoding: .utf8) { print(line); fflush(stdout) }
    }
    func run() -> Int32 {
        absoluteWatchdog = watchdog(after: 180)
        defer { absoluteWatchdog?.cancel(); activeWatchdog?.cancel() }
        let fans = sampler.sample().fans
        for fan in fans {
            guard let lo = fan.minimumRPM, let hi = fan.maximumRPM, lo <= hi else { emit("failed", "无法读取范围"); return 1 }
            targets[fan.id] = min(hi, max(lo, 3500))
        }
        guard !targets.isEmpty else { emit("failed", "无法读取风扇"); return 1 }
        controller.onStateChange = { [weak self] _, message in self?.emit("status", message); recordFanStatus(message) }
        emit("begin", "短时3500RPM测试，结束后切回系统；助手安装状态=\(controller.installationState)")
        controller.setTargets(targets) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success:
                activeWatchdog = watchdog(after: 45)
                emit("targets_confirmed"); observe()
            case .failure(let error):
                recordFanStatus(error.message); emit("failed", error.message)
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) { self.emit("after_failure"); self.finished = true }
            }
        }
        let deadline = Date().addingTimeInterval(180)
        while !finished && Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.1)) }
        if !finished { emit("failed", "验证超时，断开会话；助手将尝试恢复，尚未确认") }
        controller.shutdown()
        return code
    }
    private func observe() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [self] in
            samples += 1
            let fans = sampler.sample().fans
            let atTarget = fans.count == targets.count && fans.allSatisfy { fan in
                guard let rpm = fan.rpm, let target = targets[fan.id], let hardwareTarget = fan.targetRPM else { return false }
                return fan.hardwareMode == 1 && abs(hardwareTarget - target) < 1 && abs(rpm - target) <= max(200, target * 0.1)
            }
            stableSamples = atTarget ? stableSamples + 1 : 0
            emit("measured", fans: fans)
            if samples < 6 { observe(); return }
            controller.restoreSystemControl { [self] result in
                switch result {
                case .success:
                    emit("system_confirmed", stableSamples >= 2 ? "末两次实测RPM达到目标且模式保持手动" : "实测RPM或模式未持续达到目标")
                    code = stableSamples >= 2 ? 0 : 2
                case .failure(let error): emit("restore_failed", error.message); code = 3
                }
                finished = true
            }
        }
    }
}

if CommandLine.arguments.contains("--fan-verify") {
    let acceptance = FanAcceptanceRun()
    let result = withExtendedLifetime(acceptance) { acceptance.run() }
    exit(result)
} else if CommandLine.arguments.contains("--fan-install-preflight") {
    let signature = Process()
    signature.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
    signature.arguments = ["--verify", "--deep", "--strict", Bundle.main.bundleURL.path]
    do {
        try signature.run(); signature.waitUntilExit()
        guard signature.terminationStatus == 0 else { print("ERROR stage=bundle_signature"); exit(1) }
        print("CHECK bundle_signature=ok")
    } catch { print("ERROR stage=bundle_signature: \(error.localizedDescription)"); exit(1) }
    let process = Process()
    process.executableURL = Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/FanHelper")
    process.arguments = ["--preflight"]
    do { try process.run(); process.waitUntilExit(); exit(process.terminationStatus) }
    catch { print("安装前检查无法启动：\(error.localizedDescription)"); exit(1) }
} else if CommandLine.arguments.contains("--fan-diagnostics") {
    let defaults = UserDefaults.standard
    let snapshot = FanSampler().sample()
    let result: [String: Any] = [
        "helperInstallationState": FanController().installationState,
        "lastStatus": defaults.string(forKey: "lastFanControlStatus") ?? "尚未记录控制请求",
        "lastStatusUnixTime": defaults.double(forKey: "lastFanControlStatusTime"),
        "fans": snapshot.fans.map { fan -> [String: Any] in
            ["id": fan.id, "rpm": fan.rpm as Any? ?? NSNull(),
             "targetRPM": fan.targetRPM as Any? ?? NSNull(),
             "mode": fan.hardwareMode as Any? ?? NSNull()]
        }]
    if let data = try? JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]),
       let text = String(data: data, encoding: .utf8) { print(text) }
} else if CommandLine.arguments.contains("--snapshot") {
    let sampler = MetricsSampler()
    _ = sampler.sample()
    Thread.sleep(forTimeInterval: 1)
    let m = sampler.sample()
    let t = TemperatureSampler().sample()
    let result: [String: Any] = ["cpuPercent": m.cpuPercent as Any? ?? NSNull(),
        "sampledAt": ISO8601DateFormatter().string(from: Date()),
        "memoryUsedBytes": m.memoryReadingAvailable ? m.memoryUsedBytes as Any : NSNull(), "memoryTotalBytes": m.memoryTotalBytes, "memoryReadingAvailable": m.memoryReadingAvailable,
        "memoryDiagnostics": m.memoryDiagnostics as Any? ?? NSNull(),
        "sampleIntervalSeconds": m.sampleInterval as Any? ?? NSNull(),
        "downloadBytesPerSecond": m.receivedBytesPerSecond as Any? ?? NSNull(),
        "uploadBytesPerSecond": m.sentBytesPerSecond as Any? ?? NSNull(),
        "interfaces": m.networkInterfaces, "temperatureCelsius": t.celsius as Any? ?? NSNull(),
        "temperatureSource": t.source, "temperatureDetail": t.detail]
    if let data = try? JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]),
       let text = String(data: data, encoding: .utf8) { print(text) }
} else {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.run()
}
