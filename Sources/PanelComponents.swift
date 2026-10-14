import AppKit

// MARK: - Layout helpers

func label(_ text: String, size: CGFloat = 12, weight: NSFont.Weight = .regular,
           color: NSColor = .labelColor, monospacedDigits: Bool = false) -> NSTextField {
    let field = NSTextField(labelWithString: text)
    field.font = monospacedDigits ? .monospacedDigitSystemFont(ofSize: size, weight: weight)
                                  : .systemFont(ofSize: size, weight: weight)
    field.textColor = color
    field.lineBreakMode = .byTruncatingTail
    return field
}

/// Wrapping text. The width is fixed up front so fitting heights, and therefore the panel size, are stable.
func paragraph(_ text: String, size: CGFloat = 11, color: NSColor = .secondaryLabelColor, width: CGFloat) -> NSTextField {
    let field = NSTextField(wrappingLabelWithString: text)
    field.font = .systemFont(ofSize: size); field.textColor = color
    field.isSelectable = false; field.preferredMaxLayoutWidth = width
    return field
}

func sectionTitle(_ text: String) -> NSTextField {
    let field = NSTextField(labelWithString: "")
    field.attributedStringValue = NSAttributedString(string: text, attributes: [
        .font: NSFont.systemFont(ofSize: 11, weight: .semibold), .foregroundColor: NSColor.secondaryLabelColor, .kern: 0.6])
    return field
}

func horizontal(_ views: [NSView], spacing: CGFloat = 8) -> NSStackView {
    let stack = NSStackView(views: views)
    stack.orientation = .horizontal; stack.spacing = spacing; stack.alignment = .centerY
    return stack
}

func vertical(_ views: [NSView], spacing: CGFloat = 8) -> NSStackView {
    let stack = NSStackView(views: views)
    stack.orientation = .vertical; stack.spacing = spacing; stack.alignment = .leading
    return stack
}

func spacer() -> NSView {
    let view = NSView()
    view.setContentHuggingPriority(.init(1), for: .horizontal)
    return view
}

func pin(_ view: NSView, in container: NSView, _ insets: NSEdgeInsets = NSEdgeInsets()) {
    view.translatesAutoresizingMaskIntoConstraints = false; container.addSubview(view)
    NSLayoutConstraint.activate([
        view.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: insets.left),
        view.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -insets.right),
        view.topAnchor.constraint(equalTo: container.topAnchor, constant: insets.top),
        view.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -insets.bottom)
    ])
}

func percentText(_ value: Double?) -> String { value.map { String(format: "%.0f%%", $0) } ?? "—" }

private let rpmFormatter: NumberFormatter = {
    let formatter = NumberFormatter(); formatter.numberStyle = .decimal; formatter.maximumFractionDigits = 0
    return formatter
}()
func rpmText(_ value: Double) -> String { rpmFormatter.string(from: NSNumber(value: value.rounded())) ?? "\(Int(value))" }

// MARK: - Colors

/// One accent for normal readings; warn and ok are reserved for state, never for decoration.
enum Palette {
    static let accent = dynamic(light: 0x0A8784, dark: 0x40C8C0)
    static let onAccent = dynamic(light: 0xFFFFFF, dark: 0x0D1415)
    static let warn = dynamic(light: 0xD06A08, dark: 0xF2A14F)
    static let ok = dynamic(light: 0x2C9A55, dark: 0x52C57F)
    static func fill(_ alpha: CGFloat = 0.05) -> NSColor { NSColor.labelColor.withAlphaComponent(alpha) }
    private static func dynamic(light: UInt32, dark: UInt32) -> NSColor {
        NSColor(name: nil) { appearance in
            let hex = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
            return NSColor(srgbRed: CGFloat(hex >> 16 & 0xFF) / 255, green: CGFloat(hex >> 8 & 0xFF) / 255,
                           blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
        }
    }
}

// MARK: - Primitive views

/// Rounded fill drawn in draw(_:), so dynamic colors follow appearance changes on their own.
class FillView: NSView {
    var fill: NSColor? { didSet { needsDisplay = true } }
    var stroke: NSColor? { didSet { needsDisplay = true } }
    var radius: CGFloat = 8
    var capsule = false
    override func draw(_ dirtyRect: NSRect) {
        let r = capsule ? bounds.height / 2 : radius
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.25, dy: 0.25), xRadius: r, yRadius: r)
        if let fill { fill.setFill(); path.fill() }
        if let stroke { stroke.setStroke(); path.lineWidth = 0.5; path.stroke() }
    }
}

final class FlippedView: NSView { override var isFlipped: Bool { true } }

/// Hairline along the top edge; used by sections and the footer.
class HairlineView: NSView {
    var showsLine = true { didSet { needsDisplay = true } }
    override func draw(_ dirtyRect: NSRect) {
        guard showsLine else { return }
        NSColor.separatorColor.withAlphaComponent(0.6).setFill()
        NSRect(x: 0, y: isFlipped ? 0 : bounds.height - 0.5, width: bounds.width, height: 0.5).fill()
    }
}

/// Recent samples as a filled line. A fixed range keeps percentages comparable;
/// a nil range scales to the visible samples (temperature, network rate).
final class Sparkline: NSView {
    var tint: NSColor = Palette.accent { didSet { if tint != oldValue { needsDisplay = true } } }
    var range: ClosedRange<Double>?
    /// Smallest span drawn when auto-scaling, so sensor noise doesn't look like a swing.
    var minimumSpan = 1e-6
    private(set) var samples: [(time: TimeInterval, value: Double)] = []
    private let capacity = 60
    var values: [Double] { samples.map(\.value) }
    /// Seconds covered by the stored samples; sampling slows down while the panel is closed.
    var span: TimeInterval? { samples.count > 1 ? samples[samples.count - 1].time - samples[0].time : nil }
    func append(_ value: Double?) {
        guard let value, value.isFinite else { return }
        samples.append((ProcessInfo.processInfo.systemUptime, value))
        if samples.count > capacity { samples.removeFirst(samples.count - capacity) }
        if !isHiddenOrHasHiddenAncestor && window?.isVisible == true { needsDisplay = true }
    }
    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); needsDisplay = true }
    override func draw(_ dirtyRect: NSRect) {
        let midY = (bounds.height / 2).rounded() + 0.5
        let grid = NSBezierPath(); grid.move(to: NSPoint(x: 0, y: midY)); grid.line(to: NSPoint(x: bounds.width, y: midY))
        grid.setLineDash([2, 3], count: 2, phase: 0); grid.lineWidth = 1
        NSColor.labelColor.withAlphaComponent(0.1).setStroke(); grid.stroke()
        let values = self.values
        guard values.count > 1, bounds.width > 0 else { return }
        var low = range?.lowerBound ?? (values.min() ?? 0)
        var high = range?.upperBound ?? (values.max() ?? 1)
        if high - low < minimumSpan { let mid = (high + low) / 2; low = mid - minimumSpan / 2; high = mid + minimumSpan / 2 }
        let inset: CGFloat = 3, height = bounds.height - inset * 2
        let step = (bounds.width - inset) / CGFloat(capacity - 1)
        let start = bounds.width - inset - step * CGFloat(values.count - 1)
        let points = values.enumerated().map { index, value -> NSPoint in
            let ratio = CGFloat((min(max(value, low), high) - low) / (high - low))
            return NSPoint(x: start + step * CGFloat(index), y: inset + ratio * height)
        }
        let line = NSBezierPath(); line.move(to: points[0])
        points.dropFirst().forEach { line.line(to: $0) }
        let fill = line.copy() as! NSBezierPath
        fill.line(to: NSPoint(x: points[points.count - 1].x, y: 0)); fill.line(to: NSPoint(x: points[0].x, y: 0)); fill.close()
        NSGradient(starting: tint.withAlphaComponent(0.26), ending: tint.withAlphaComponent(0))?.draw(in: fill, angle: -90)
        tint.setStroke(); line.lineWidth = 1.5; line.lineJoinStyle = .round; line.stroke()
        let end = points[points.count - 1]
        tint.setFill(); NSBezierPath(ovalIn: NSRect(x: end.x - 2.4, y: end.y - 2.4, width: 4.8, height: 4.8)).fill()
    }
}

/// Thin capsule bar; drawn directly so it keeps its tint when the panel is not key.
final class LevelBar: NSView {
    var fraction: Double = 0 { didSet { if fraction != oldValue { needsDisplay = true } } }
    var tint: NSColor = Palette.accent { didSet { needsDisplay = true } }
    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: 6) }
    override func draw(_ dirtyRect: NSRect) {
        let radius = bounds.height / 2
        Palette.fill(0.09).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: radius, yRadius: radius).fill()
        guard fraction > 0 else { return }
        var filled = bounds; filled.size.width = max(bounds.height, bounds.width * CGFloat(min(fraction, 1)))
        tint.setFill(); NSBezierPath(roundedRect: filled, xRadius: radius, yRadius: radius).fill()
    }
}

final class StatusDot: NSView {
    var color: NSColor = .tertiaryLabelColor { didSet { needsDisplay = true } }
    var halo = false { didSet { needsDisplay = true } }
    private let diameter: CGFloat
    init(diameter: CGFloat = 6, frameSize: CGFloat = 6) {
        self.diameter = diameter
        super.init(frame: NSRect(x: 0, y: 0, width: frameSize, height: frameSize))
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override var intrinsicContentSize: NSSize { frame.size }
    override func draw(_ dirtyRect: NSRect) {
        let center = NSPoint(x: bounds.midX, y: bounds.midY)
        if halo {
            let r = min(bounds.width, bounds.height) / 2
            color.withAlphaComponent(0.2).setFill()
            NSBezierPath(ovalIn: NSRect(x: center.x - r, y: center.y - r, width: r * 2, height: r * 2)).fill()
        }
        color.setFill()
        NSBezierPath(ovalIn: NSRect(x: center.x - diameter / 2, y: center.y - diameter / 2, width: diameter, height: diameter)).fill()
    }
}

/// The header summary: one pill that always shows the single most important state.
final class StatusChip: FillView {
    enum Tone { case ok, warn, neutral }
    private let dot = StatusDot()
    private let text = label("", size: 11, weight: .medium, color: .secondaryLabelColor)
    init() {
        super.init(frame: .zero)
        capsule = true
        pin(horizontal([dot, text], spacing: 5), in: self, NSEdgeInsets(top: 3, left: 8, bottom: 3, right: 9))
        setAccessibilityElement(true); setAccessibilityRole(.staticText)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func show(_ tone: Tone, _ message: String) {
        if text.stringValue != message { text.stringValue = message }
        switch tone {
        case .ok: fill = Palette.fill(); dot.color = Palette.ok; text.textColor = .secondaryLabelColor
        case .warn: fill = Palette.warn.withAlphaComponent(0.13); dot.color = Palette.warn; text.textColor = Palette.warn
        case .neutral: fill = Palette.fill(); dot.color = .tertiaryLabelColor; text.textColor = .secondaryLabelColor
        }
        setAccessibilityLabel("状态：" + message)
    }
}

// MARK: - Rows

/// Shared hover and click handling for the clickable rows.
class HoverView: NSView {
    var hovering = false { didSet { if hovering != oldValue { needsDisplay = true } } }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    /// The whole row is one target; labels and the trend line inside it don't take clicks.
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let superview else { return nil }
        return frame.contains(superview.convert(point, to: superview)) && !isHidden ? self : nil
    }
    /// Rows join the Tab order only with full keyboard access, so opening the panel doesn't ring the first row.
    override var acceptsFirstResponder: Bool { NSApp.isFullKeyboardAccessEnabled }
    override var canBecomeKeyView: Bool { NSApp.isFullKeyboardAccessEnabled }
    override func keyDown(with event: NSEvent) {
        if event.charactersIgnoringModifiers == " " || event.keyCode == 36 { clicked() } else { super.keyDown(with: event) }
    }
    override var focusRingMaskBounds: NSRect { bounds }
    override func drawFocusRingMask() { NSBezierPath(roundedRect: bounds, xRadius: 7, yRadius: 7).fill() }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }
    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }
    override func mouseDown(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) {
        if bounds.contains(convert(event.locationInWindow, from: nil)) { clicked() }
    }
    func clicked() {}
}

/// Column grid shared by metric and fan rows so names, trends and values line up across modules.
enum RowGrid {
    static let padding: CGFloat = 6, name: CGFloat = 78, value: CGFloat = 90, gap: CGFloat = 10
}

private final class StatTile: FillView {
    let value = label("—", size: 12, weight: .semibold, monospacedDigits: true)
    init(_ caption: String) {
        super.init(frame: .zero)
        fill = Palette.fill(); radius = 6
        pin(vertical([label(caption, size: 10.5, color: .secondaryLabelColor), value], spacing: 1),
            in: self, NSEdgeInsets(top: 4, left: 7, bottom: 4, right: 7))
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

/// Name · recent trend · current value. Clicking expands min/avg/max over the stored samples.
final class MetricRow: HoverView {
    let trend = Sparkline()
    var onToggle: (() -> Void)?
    private(set) var expanded = false
    private let title: String
    private let explanation: String
    private let format: (Double) -> String
    private let baseTint: NSColor
    private let subtitle = label("", size: 10.5, color: .secondaryLabelColor, monospacedDigits: true)
    private let value = label("—", size: 15, weight: .semibold, monospacedDigits: true)
    private let detail = NSView()
    private let stats = [StatTile("最低"), StatTile("平均"), StatTile("最高")]
    private let note: NSTextField

    init(title: String, explanation: String, tint: NSColor = Palette.accent, range: ClosedRange<Double>?,
         minimumSpan: Double = 1e-6, format: @escaping (Double) -> String) {
        self.title = title; self.explanation = explanation; self.format = format; baseTint = tint
        note = paragraph(explanation, width: PanelViewController.width - 16 - RowGrid.padding * 2)
        super.init(frame: .zero)
        trend.tint = tint; trend.range = range; trend.minimumSpan = minimumSpan
        let names = vertical([label(title, size: 13, weight: .medium), subtitle], spacing: 1)
        value.alignment = .right
        let header = NSView()
        for view in [names, trend, value] { view.translatesAutoresizingMaskIntoConstraints = false; header.addSubview(view) }
        NSLayoutConstraint.activate([
            names.leadingAnchor.constraint(equalTo: header.leadingAnchor, constant: RowGrid.padding),
            names.widthAnchor.constraint(equalToConstant: RowGrid.name),
            names.topAnchor.constraint(equalTo: header.topAnchor, constant: 3),
            names.bottomAnchor.constraint(equalTo: header.bottomAnchor, constant: -3),
            trend.leadingAnchor.constraint(equalTo: names.trailingAnchor, constant: RowGrid.gap),
            trend.trailingAnchor.constraint(equalTo: value.leadingAnchor, constant: -RowGrid.gap),
            trend.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            trend.heightAnchor.constraint(equalToConstant: 26),
            value.trailingAnchor.constraint(equalTo: header.trailingAnchor, constant: -RowGrid.padding),
            value.widthAnchor.constraint(equalToConstant: RowGrid.value),
            value.centerYAnchor.constraint(equalTo: header.centerYAnchor)
        ])
        let tiles = horizontal(stats, spacing: 6); tiles.distribution = .fillEqually
        let detailStack = vertical([tiles, note], spacing: 6)
        pin(detailStack, in: detail, NSEdgeInsets(top: 1, left: RowGrid.padding, bottom: 8, right: RowGrid.padding))
        tiles.widthAnchor.constraint(equalTo: detailStack.widthAnchor).isActive = true
        detail.isHidden = true
        let outer = vertical([header, detail], spacing: 0)
        pin(outer, in: self)
        for view in [header, detail] { view.widthAnchor.constraint(equalTo: outer.widthAnchor).isActive = true }
        setAccessibilityElement(true); setAccessibilityRole(.button)
        setAccessibilityHelp("显示近期最低、平均和最高值")
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func show(_ text: String, subtitle sub: String, warning: Bool = false) {
        if value.stringValue != text { value.stringValue = text }
        if subtitle.stringValue != sub { subtitle.stringValue = sub }
        value.textColor = warning ? Palette.warn : .labelColor
        trend.tint = warning ? Palette.warn : baseTint
        setAccessibilityLabel("\(title) \(text)")
        if expanded { refreshStats() }
    }
    func setExpanded(_ on: Bool) {
        guard on != expanded else { return }
        expanded = on; detail.isHidden = !on; needsDisplay = true
        setAccessibilityExpanded(on)
        if on { refreshStats() }
    }
    private func refreshStats() {
        let values = trend.values
        let texts = values.isEmpty ? ["—", "—", "—"]
            : [format(values.min()!), format(values.reduce(0, +) / Double(values.count)), format(values.max()!)]
        for (tile, text) in zip(stats, texts) where tile.value.stringValue != text { tile.value.stringValue = text }
        var window = "等待更多采样"
        if let span = trend.span, span >= 5 {
            window = span < 90 ? "近 \(Int(span.rounded())) 秒统计" : "近 \(Int((span / 60).rounded())) 分钟统计"
        }
        let text = window + " · " + explanation
        if note.stringValue != text { note.stringValue = text }
    }
    override func clicked() { onToggle?() }
    override func accessibilityPerformPress() -> Bool { onToggle?(); return true }
    override func draw(_ dirtyRect: NSRect) {
        guard hovering || expanded else { return }
        Palette.fill(expanded ? 0.05 : 0.045).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 7, yRadius: 7).fill()
    }
}

final class FanRow: NSView {
    private let name = label("风扇", size: 13, weight: .medium)
    private let bar = LevelBar()
    private let value = label("—", size: 13, weight: .semibold, monospacedDigits: true)
    init(_ index: Int) {
        super.init(frame: .zero)
        name.stringValue = "风扇 \(index + 1)"
        value.alignment = .right
        for view in [name, bar, value] { view.translatesAutoresizingMaskIntoConstraints = false; addSubview(view) }
        NSLayoutConstraint.activate([
            name.leadingAnchor.constraint(equalTo: leadingAnchor, constant: RowGrid.padding),
            name.widthAnchor.constraint(equalToConstant: RowGrid.name),
            name.centerYAnchor.constraint(equalTo: centerYAnchor),
            bar.leadingAnchor.constraint(equalTo: name.trailingAnchor, constant: RowGrid.gap),
            bar.trailingAnchor.constraint(equalTo: value.leadingAnchor, constant: -RowGrid.gap),
            bar.centerYAnchor.constraint(equalTo: centerYAnchor),
            value.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -RowGrid.padding),
            value.widthAnchor.constraint(equalToConstant: RowGrid.value),
            value.centerYAnchor.constraint(equalTo: centerYAnchor),
            heightAnchor.constraint(equalToConstant: 26)
        ])
        setAccessibilityElement(true); setAccessibilityRole(.staticText)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func show(_ fan: FanReading, boost: Bool) {
        bar.tint = boost ? Palette.warn : Palette.accent
        let text: String
        if let rpm = fan.rpm {
            text = rpm == 0 ? "停转" : rpmText(rpm) + " RPM"
            value.textColor = rpm == 0 ? .secondaryLabelColor : .labelColor
            if rpm > 0, let high = fan.maximumRPM, high > 0 {
                let low = min(fan.minimumRPM ?? 0, high)
                bar.fraction = high > low ? min(max((rpm - low) / (high - low), 0.03), 1) : 1
            } else { bar.fraction = 0 }
        } else {
            text = "—"; value.textColor = .secondaryLabelColor; bar.fraction = 0
        }
        if value.stringValue != text { value.stringValue = text }
        setAccessibilityLabel(name.stringValue + " " + (text == "—" ? "转速不可读" : text))
    }
}

/// One panel module: small caps title, optional accessory on the right, rows below.
final class ModuleSection: HairlineView {
    let accessory = label("", size: 11, color: .secondaryLabelColor, monospacedDigits: true)
    private let content = NSStackView()
    init(title: String) {
        super.init(frame: .zero)
        let heading = sectionTitle(title)
        content.orientation = .vertical; content.alignment = .leading; content.spacing = 0
        accessory.alignment = .right
        for view in [heading, accessory, content] { view.translatesAutoresizingMaskIntoConstraints = false; addSubview(view) }
        NSLayoutConstraint.activate([
            heading.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            heading.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            accessory.firstBaselineAnchor.constraint(equalTo: heading.firstBaselineAnchor),
            accessory.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            accessory.leadingAnchor.constraint(greaterThanOrEqualTo: heading.trailingAnchor, constant: 8),
            content.topAnchor.constraint(equalTo: heading.bottomAnchor, constant: 3),
            content.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            content.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            content.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -6)
        ])
        setAccessibilityElement(false); setAccessibilityRole(.group); setAccessibilityLabel(title)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    /// Rows fill the width; other content gets the row padding so its text lines up with row text.
    @discardableResult
    func add(_ view: NSView, inset: CGFloat = 0, spacingBefore: CGFloat = 0) -> NSView {
        var item = view
        if inset > 0 {
            item = NSView()
            pin(view, in: item, NSEdgeInsets(top: 0, left: inset, bottom: 0, right: inset))
        }
        if spacingBefore > 0, let last = content.arrangedSubviews.last { content.setCustomSpacing(spacingBefore, after: last) }
        content.addArrangedSubview(item)
        item.widthAnchor.constraint(equalTo: content.widthAnchor).isActive = true
        return item
    }
}

/// Toggle chip with an order badge, used for the menu bar picks.
final class PillButton: HoverView {
    let title: String
    var order: Int? { didSet { if order != oldValue { needsDisplay = true; invalidateIntrinsicContentSize(); updateAccessibility() } } }
    var onClick: (() -> Void)?
    private let font = NSFont.systemFont(ofSize: 12)
    init(_ title: String) {
        self.title = title
        super.init(frame: .zero)
        setAccessibilityElement(true); setAccessibilityRole(.checkBox); updateAccessibility()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    private var textWidth: CGFloat { ceil((title as NSString).size(withAttributes: [.font: font]).width) }
    override var intrinsicContentSize: NSSize { NSSize(width: textWidth + (order == nil ? 22 : 37), height: 24) }
    private func updateAccessibility() {
        setAccessibilityLabel(title); setAccessibilityValue(order.map { "第 \($0) 项" } ?? "未显示")
    }
    override func clicked() { onClick?() }
    override func accessibilityPerformPress() -> Bool { onClick?(); return true }
    override func draw(_ dirtyRect: NSRect) {
        let shape = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: bounds.height / 2, yRadius: bounds.height / 2)
        var textColor = NSColor.labelColor, x: CGFloat = 11
        if let order {
            Palette.accent.setFill(); shape.fill(); textColor = Palette.onAccent; x = 26
            let badge = NSRect(x: 5.5, y: (bounds.height - 15) / 2, width: 15, height: 15)
            Palette.onAccent.withAlphaComponent(0.25).setFill(); NSBezierPath(ovalIn: badge).fill()
            let digit = NSAttributedString(string: "\(order)", attributes: [
                .font: NSFont.systemFont(ofSize: 9.5, weight: .bold), .foregroundColor: Palette.onAccent])
            let size = digit.size()
            digit.draw(at: NSPoint(x: badge.midX - size.width / 2, y: badge.midY - size.height / 2))
        } else {
            if hovering { Palette.fill().setFill(); shape.fill() }
            Palette.fill(0.16).setStroke(); shape.lineWidth = 1; shape.stroke()
        }
        let text = NSAttributedString(string: title, attributes: [.font: font, .foregroundColor: textColor])
        text.draw(at: NSPoint(x: x, y: (bounds.height - text.size().height) / 2))
    }
}

/// Editing is local only. Hardware changes are submitted by the panel's Apply button.
final class FanTargetEditor: NSView {
    private let slider: NSSlider
    private let targetLabel = label("", size: 11, monospacedDigits: true)
    var value: Double { slider.doubleValue.rounded() }
    var isEnabled: Bool { get { slider.isEnabled } set { slider.isEnabled = newValue } }
    init(id: Int, range: ClosedRange<Double>, value: Double) {
        slider = NSSlider(value: value, minValue: ceil(range.lowerBound), maxValue: floor(range.upperBound), target: nil, action: nil)
        super.init(frame: .zero)
        slider.controlSize = .small; slider.isContinuous = true
        slider.target = self; slider.action = #selector(changed)
        slider.setAccessibilityLabel("风扇 \(id + 1) 目标转速")
        let heading = horizontal([label("风扇 \(id + 1)", size: 11), spacer(), targetLabel], spacing: 4)
        let limits = label("\(rpmText(range.lowerBound))–\(rpmText(range.upperBound)) RPM", size: 10, color: .secondaryLabelColor)
        let stack = vertical([heading, slider, limits], spacing: 1)
        pin(stack, in: self)
        for row in [heading as NSView, slider] { row.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true }
        changed()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    @objc private func changed() { targetLabel.stringValue = rpmText(value) + " RPM" }
}
