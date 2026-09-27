import AppKit
import Combine
import ServiceManagement
import SwiftUI

// MARK: - Desktop widget window

final class WidgetPanel: NSPanel {
    init(size: NSSize) {
        super.init(contentRect: NSRect(origin: .zero, size: size),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenNone]
    }
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Drag anywhere to move, double-click to refresh, right-click for the menu.
final class DragHostingView<Content: View>: NSHostingView<Content> {
    var onDoubleClick: (() -> Void)?
    var onPress: (() -> Void)?
    var onContextClick: ((NSView) -> Void)?

    override func mouseDown(with event: NSEvent) {
        onPress?()
        if event.modifierFlags.contains(.control) { return rightMouseDown(with: event) }
        if event.clickCount >= 2 { onDoubleClick?(); return }
        window?.performDrag(with: event)
    }
    override func rightMouseDown(with event: NSEvent) {
        onPress?()
        onContextClick?(self)
    }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

@MainActor
final class WidgetController: NSObject {
    private let store: UsageStore
    private let settings: Settings
    private var panel: WidgetPanel?
    private var glass: NSGlassEffectView?
    private var host: DragHostingView<WidgetRoot>?
    /// Opens the control panel next to the widget.
    var contextHandler: ((NSView) -> Void)?

    private static let desktopLevel = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopIconWindow)) + 1)

    init(store: UsageStore, settings: Settings) {
        self.store = store
        self.settings = settings
    }

    func apply() {
        guard settings.showWidget else { panel?.orderOut(nil); return }
        if panel == nil { build() }
        guard let panel, let glass else { return }

        panel.level = settings.placement == .desktop && !raised ? Self.desktopLevel : .floating
        glass.cornerRadius = settings.widgetSize == .large ? 30 : 24
        switch settings.glassStyle {
        case .regular:
            glass.style = .regular; glass.tintColor = nil; panel.appearance = nil
        case .clear:
            glass.style = .clear; glass.tintColor = nil; panel.appearance = nil
        case .dark:
            glass.style = .regular
            glass.tintColor = NSColor(white: 0.06, alpha: 0.55)
            panel.appearance = NSAppearance(named: .darkAqua)
        }
        fit()
        panel.orderFrontRegardless()
    }

    private var raised = false
    private var outsideClickMonitor: Any?

    /// Brings a desktop-level widget in front of other windows until the next click elsewhere.
    func raise() {
        guard settings.showWidget, settings.placement == .desktop, let panel, !raised else { return }
        raised = true
        panel.level = .floating
        panel.orderFrontRegardless()
        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] _ in
            Task { @MainActor in self?.lower() }
        }
    }

    func lower() {
        if let m = outsideClickMonitor { NSEvent.removeMonitor(m) }
        outsideClickMonitor = nil
        guard raised else { return }
        raised = false
        if settings.placement == .desktop { panel?.level = Self.desktopLevel }
    }

    /// Keeps the window hugging the SwiftUI content. It stays anchored at the top, grows leftwards
    /// when it sits against the right edge of the screen, and never ends up partly off-screen.
    func fit() {
        guard let panel, let host else { return }
        let size = host.fittingSize
        guard size.width > 1, size.height > 1 else { return }
        let old = panel.frame
        var frame = NSRect(x: old.minX, y: old.maxY - size.height, width: size.width, height: size.height)

        let screen = NSScreen.screens.first { $0.frame.intersects(old) } ?? NSScreen.main
        if let vf = screen?.visibleFrame {
            if abs(vf.maxX - old.maxX) < 80 { frame.origin.x = old.maxX - size.width }
            frame.origin.x = min(max(frame.origin.x, vf.minX), vf.maxX - size.width)
            frame.origin.y = min(max(frame.origin.y, vf.minY), vf.maxY - size.height)
        }
        guard frame.integral != old.integral else { return }
        panel.setFrame(frame, display: true, animate: false)
    }

    private func build() {
        let host = DragHostingView(rootView: WidgetRoot(store: store, settings: settings))
        host.sizingOptions = [.intrinsicContentSize]
        host.onDoubleClick = { [weak self] in self?.store.refresh(manual: true) }
        host.onPress = { [weak self] in
            self?.raise()
            WorkActivityStore.shared.markSeen()   // a click on the widget acknowledges finished work
        }
        host.onContextClick = { [weak self] view in self?.contextHandler?(view) }
        let size = host.fittingSize

        let glass = NSGlassEffectView(frame: NSRect(origin: .zero, size: size))
        glass.cornerRadius = 24
        glass.contentView = host
        host.frame = glass.bounds
        host.autoresizingMask = [.width, .height]

        let panel = WidgetPanel(size: size)
        panel.contentView = glass
        panel.setFrameTopLeftPoint(restoredTopLeft(for: size))
        NotificationCenter.default.addObserver(self, selector: #selector(didMove),
                                               name: NSWindow.didMoveNotification, object: panel)
        NotificationCenter.default.addObserver(self, selector: #selector(occlusionChanged),
                                               name: NSWindow.didChangeOcclusionStateNotification, object: panel)
        self.host = host
        self.glass = glass
        self.panel = panel
    }

    private func restoredTopLeft(for size: NSSize) -> NSPoint {
        if let a = UserDefaults.standard.array(forKey: "widgetTopLeft") as? [Double], a.count == 2 {
            let p = NSPoint(x: a[0], y: a[1])
            let probe = NSPoint(x: p.x + 30, y: p.y - 30)
            if NSScreen.screens.contains(where: { $0.frame.contains(probe) }) { return p }
        }
        let vf = (NSScreen.main ?? NSScreen.screens[0]).visibleFrame
        return NSPoint(x: vf.maxX - size.width - 28, y: vf.maxY - 28)
    }

    @objc private func occlusionChanged(_ note: Notification) {
        guard let panel else { return }
        let visible = panel.isVisible && panel.occlusionState.contains(.visible)
        if SceneVisibility.shared.visible != visible { SceneVisibility.shared.visible = visible }
    }

    @objc private func didMove(_ note: Notification) {
        guard let f = panel?.frame else { return }
        UserDefaults.standard.set([Double(f.minX), Double(f.maxY)], forKey: "widgetTopLeft")
    }
}

// MARK: - Menu bar

enum StatusIcon {
    struct Segment {
        var provider: Provider
        var outer: Double
        var inner: Double?          // nil → draw the service mark in the middle instead
        var outerColor: NSColor
        var innerColor: NSColor
        var text: String
        var dimmed: Bool
    }

    private static let ring: CGFloat = 18
    private static let textGap: CGFloat = 3
    private static let segmentGap: CGFloat = 9

    /// One ring (plus optional figure) per service, drawn into a single image.
    static func make(_ segments: [Segment]) -> NSImage {
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium)]
        let widths = segments.map { s -> CGFloat in
            s.text.isEmpty ? ring : ring + textGap + ceil((s.text as NSString).size(withAttributes: attrs).width)
        }
        let total = widths.reduce(0, +) + segmentGap * CGFloat(max(0, segments.count - 1))

        let img = NSImage(size: NSSize(width: max(total, ring), height: ring), flipped: false) { rect in
            var x: CGFloat = 0
            for (i, s) in segments.enumerated() {
                let c = NSPoint(x: x + ring / 2, y: rect.midY)
                arc(c, radius: 7.4, fraction: s.outer, color: s.outerColor, dimmed: s.dimmed)
                if let inner = s.inner {
                    arc(c, radius: 3.9, fraction: inner, color: s.innerColor, dimmed: s.dimmed)
                } else {
                    mark(s.provider, center: c)
                }
                if !s.text.isEmpty {
                    var a = attrs
                    a[.foregroundColor] = NSColor.labelColor
                    let h = (s.text as NSString).size(withAttributes: a).height
                    (s.text as NSString).draw(at: NSPoint(x: x + ring + textGap, y: rect.midY - h / 2), withAttributes: a)
                }
                x += widths[i] + segmentGap
            }
            return true
        }
        img.isTemplate = false
        return img
    }

    private static func arc(_ c: NSPoint, radius: CGFloat, fraction: Double, color: NSColor, dimmed: Bool) {
        let onDark = NSAppearance.currentDrawing().bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let color = CharacterScale.legible(color, onDark: onDark)
        let track = NSBezierPath()
        track.appendArc(withCenter: c, radius: radius, startAngle: 0, endAngle: 360)
        track.lineWidth = 2.3
        NSColor.labelColor.withAlphaComponent(0.2).setStroke()
        track.stroke()
        guard fraction > 0.005 else { return }
        let a = NSBezierPath()
        a.appendArc(withCenter: c, radius: radius, startAngle: 90,
                    endAngle: 90 - 360 * CGFloat(min(fraction, 0.999)), clockwise: true)
        a.lineWidth = 2.3
        a.lineCapStyle = .round
        color.withAlphaComponent(dimmed ? 0.4 : 1).setStroke()
        a.stroke()
    }

    /// The service mark: ✳︎ for Claude, ›_ for Codex. `size` 1 ≈ 7pt across.
    static func mark(_ p: Provider, center c: NSPoint, size k: CGFloat = 1, color: NSColor? = nil) {
        let path = NSBezierPath()
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        switch p {
        case .claude:
            for i in 0..<8 {
                let a = CGFloat(i) / 8 * 2 * .pi
                path.move(to: NSPoint(x: c.x + cos(a) * 0.9 * k, y: c.y + sin(a) * 0.9 * k))
                path.line(to: NSPoint(x: c.x + cos(a) * 3.4 * k, y: c.y + sin(a) * 3.4 * k))
            }
            path.lineWidth = 1.2 * max(1, k * 0.9)
            (color ?? NSColor(Palette.claudeAccent)).setStroke()
        case .codex:
            path.move(to: NSPoint(x: c.x - 2.6 * k, y: c.y + 2.6 * k))
            path.line(to: NSPoint(x: c.x, y: c.y))
            path.line(to: NSPoint(x: c.x - 2.6 * k, y: c.y - 2.6 * k))
            path.move(to: NSPoint(x: c.x + 0.8 * k, y: c.y - 2.6 * k))
            path.line(to: NSPoint(x: c.x + 3.2 * k, y: c.y - 2.6 * k))
            path.lineWidth = 1.3 * max(1, k * 0.9)
            (color ?? NSColor(Palette.codexAccent)).setStroke()
        }
        path.stroke()
    }

    // MARK: Compact styles

    struct Row {
        var provider: Provider
        var fraction: Double
        var color: NSColor
        var text: String
        var dimmed: Bool
    }

    /// Short horizontal bars stacked in rows — length reads better than a tiny ring.
    static func bars(_ rows: [Row], leading: Provider?) -> NSImage {
        let h: CGFloat = 18, barW: CGFloat = 22
        let barH: CGFloat = rows.count > 1 ? 5 : 6
        let markW: CGFloat = leading != nil ? 15 : 11
        return NSImage(size: NSSize(width: markW + barW, height: h), flipped: false) { _ in
            let rowH = h / CGFloat(rows.count)
            if let lp = leading { mark(lp, center: NSPoint(x: 6, y: h / 2), size: 1.3) }
            for (i, r) in rows.enumerated() {
                let cy = h - rowH * (CGFloat(i) + 0.5)
                if leading == nil { mark(r.provider, center: NSPoint(x: 4.5, y: cy), size: 0.95) }
                let track = NSRect(x: markW, y: cy - barH / 2, width: barW, height: barH)
                NSColor.labelColor.withAlphaComponent(0.2).setFill()
                NSBezierPath(roundedRect: track, xRadius: barH / 2, yRadius: barH / 2).fill()
                let f = CGFloat(min(max(r.fraction, 0), 1))
                guard f > 0.005 else { continue }
                r.color.withAlphaComponent(r.dimmed ? 0.4 : 1).setFill()
                let fill = NSRect(x: markW, y: cy - barH / 2, width: max(barH, barW * f), height: barH)
                NSBezierPath(roundedRect: fill, xRadius: barH / 2, yRadius: barH / 2).fill()
            }
            return true
        }
    }

    /// Numbers stacked in two lines, each led by a mark tinted with its level colour.
    static func stacked(_ rows: [Row], leading: Provider?) -> NSImage {
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .semibold)]
        let textW = rows.map { ceil(($0.text as NSString).size(withAttributes: attrs).width) }.max() ?? 0
        let h: CGFloat = 22
        let markW: CGFloat = leading != nil ? 19 : 11
        let w = markW + textW + 1
        return NSImage(size: NSSize(width: w, height: h), flipped: false) { _ in
            let rowH = h / CGFloat(rows.count)
            if let lp = leading { mark(lp, center: NSPoint(x: 6, y: h / 2), size: 1.3) }
            for (i, r) in rows.enumerated() {
                let cy = h - rowH * (CGFloat(i) + 0.5)
                if leading == nil {
                    mark(r.provider, center: NSPoint(x: 4.5, y: cy), size: 0.95, color: r.color)
                } else {
                    r.color.setFill()
                    NSBezierPath(ovalIn: NSRect(x: markW - 5, y: cy - 1.8, width: 3.6, height: 3.6)).fill()
                }
                var a = attrs
                a[.foregroundColor] = r.dimmed ? NSColor.secondaryLabelColor : NSColor.labelColor
                let size = (r.text as NSString).size(withAttributes: a)
                (r.text as NSString).draw(at: NSPoint(x: w - size.width - 0.5, y: cy - size.height / 2), withAttributes: a)
            }
            return true
        }
    }

    // MARK: Pixel mascot

    /// Claude Code's pixel character: `#` body, `o` eye.
    static let clawd = ["..############..",
                        "..############..",
                        "..##o######o##..",
                        "..##o######o##..",
                        "################",
                        "################",
                        "..############..",
                        "..############..",
                        "...#.#....#.#...",
                        "...#.#....#.#..."]
    // Three device pixels per cell on Retina; the taller head fits the 22-point menu bar.
    static let cell: CGFloat = 1.5
    static var characterSize: NSSize { NSSize(width: CGFloat(clawd[0].count) * cell, height: CGFloat(clawd.count) * cell) }

    /// Integer-point motion keeps the pixel edges crisp at menu bar scale.
    struct CharacterPose {
        var lift: CGFloat = 0
        var stepping = false
        var eyesClosed = false

        static let resting = CharacterPose()
        static let blink = CharacterPose(eyesClosed: true)
        static let loading: [CharacterPose] = [
            .init(stepping: true), .init(lift: 1, stepping: true),
            .init(lift: 2), .init(lift: 2), .init(lift: 1),
            .resting, .init(stepping: true), .resting
        ]
    }

    /// Draws the character as a gauge: the legs always carry the colour, and the body fills
    /// bottom-up with `fraction` like a water level over a faint tint of the same colour.
    static func drawCharacter(at o: NSPoint, fraction: Double, color: NSColor, dimmed: Bool,
                              pose: CharacterPose = .resting) {
        let rows = clawd.count, legRows = 2
        let bodyBottom = o.y + CGFloat(legRows) * cell
        let fillTop = bodyBottom + CGFloat(rows - legRows) * cell * CGFloat(min(max(fraction, 0), 1))
        let onDark = NSAppearance.currentDrawing().bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let color = CharacterScale.legible(color, onDark: onDark)
        let solid = color.withAlphaComponent(dimmed ? 0.45 : 1)
        let faint = dimmed ? NSColor.labelColor.withAlphaComponent(0.18) : color.withAlphaComponent(0.3)
        for (r, line) in clawd.enumerated() {
            let y = o.y + CGFloat(rows - 1 - r) * cell
            let isLeg = r >= rows - legRows
            for (c, ch) in line.enumerated() where ch != "." {
                let x = o.x + CGFloat(c) * cell
                let split = isLeg ? cell : min(max(fillTop - y, 0), cell)
                if split > 0 {
                    solid.setFill()
                    let foot = pose.stepping && r == rows - 1 && (c == 3 || c == 10) ? CGFloat(1) : 0
                    NSRect(x: x, y: y - foot, width: cell, height: split + foot).fill(using: .sourceOver)
                }
                if split < cell {
                    faint.setFill()
                    NSRect(x: x, y: y + split, width: cell, height: cell - split).fill(using: .sourceOver)
                }
                if ch == "o", !pose.eyesClosed || r == 3 {
                    (y + cell / 2 < fillTop ? NSColor(white: 0.08, alpha: 1) : NSColor.labelColor.withAlphaComponent(0.85)).setFill()
                    NSRect(x: x, y: y, width: cell,
                           height: pose.eyesClosed ? 1 : cell).fill(using: .sourceOver)
                }
            }
        }
    }

    static func character(fraction: Double, color: NSColor, dimmed: Bool, pose: CharacterPose = .resting) -> NSImage {
        let size = characterSize
        return NSImage(size: NSSize(width: size.width, height: 22), flipped: false) { _ in
            drawCharacter(at: NSPoint(x: 0, y: (22 - size.height) / 2 + pose.lift), fraction: fraction, color: color, dimmed: dimmed, pose: pose)
            return true
        }
    }

    /// The character followed by 5-hour and weekly figures in two lines.
    static func characterNumbers(fraction: Double, color: NSColor, dimmed: Bool, pose: CharacterPose = .resting, rows: [Row]) -> NSImage {
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .semibold)]
        let textW = rows.map { ceil(($0.text as NSString).size(withAttributes: attrs).width) }.max() ?? 0
        let size = characterSize, h: CGFloat = 22, gap: CGFloat = 4, dot: CGFloat = 6
        let w = size.width + gap + dot + textW + 1
        return NSImage(size: NSSize(width: w, height: h), flipped: false) { _ in
            drawCharacter(at: NSPoint(x: 0, y: (h - size.height) / 2 + pose.lift), fraction: fraction, color: color, dimmed: dimmed, pose: pose)
            let rowH = h / CGFloat(rows.count)
            for (i, r) in rows.enumerated() {
                let cy = h - rowH * (CGFloat(i) + 0.5)
                r.color.setFill()
                NSBezierPath(ovalIn: NSRect(x: size.width + gap, y: cy - 1.8, width: 3.6, height: 3.6)).fill()
                var a = attrs
                a[.foregroundColor] = r.dimmed ? NSColor.secondaryLabelColor : NSColor.labelColor
                let t = (r.text as NSString).size(withAttributes: a)
                (r.text as NSString).draw(at: NSPoint(x: w - t.width - 0.5, y: cy - t.height / 2), withAttributes: a)
            }
            return true
        }
    }

    @MainActor
    static func characterTint(_ m: Metric, _ option: CharacterColor) -> NSColor {
        if option == .claude {
            return NSColor(m.level == .critical ? Palette.red[1] : Palette.claudeAccent)
        }
        return CharacterScale.nsColor(CharacterScale.hex(forUsed: m.used, in: Settings.shared.characterSteps))
    }

    /// Builds the status item image for the chosen style.
    @MainActor
    static func image(for states: [ProviderState], style: MenuBarMode, display: DisplayMode,
                      characterColor: CharacterColor = .level, pose: CharacterPose = .resting) -> NSImage {
        let single = states.count == 1
        func dimmed(_ p: ProviderState) -> Bool { p.snapshot == nil || (p.error != nil && !p.softError) }
        func row(_ p: ProviderState, _ m: Metric) -> Row {
            Row(provider: p.provider, fraction: m.fraction(display), color: NSColor(m.colors[1]),
                text: p.snapshot == nil ? "–" : "\(m.value(display))", dimmed: dimmed(p))
        }
        let rows = single ? [row(states[0], states[0].fiveHour), row(states[0], states[0].weekly)]
                          : states.map { row($0, $0.fiveHour) }

        switch style {
        case .character, .characterNumbers:
            let p = states.first { $0.provider == .claude } ?? states[0]
            let m = p.fiveHour
            let tint = characterTint(m, characterColor)
            if style == .character {
                return character(fraction: m.fraction(display), color: tint, dimmed: dimmed(p), pose: pose)
            }
            return characterNumbers(fraction: m.fraction(display), color: tint, dimmed: dimmed(p), pose: pose,
                                    rows: [row(p, p.fiveHour), row(p, p.weekly)])
        case .bars:
            return bars(rows, leading: single ? states[0].provider : nil)
        case .stacked:
            return stacked(rows, leading: single ? states[0].provider : nil)
        case .worst:
            // The single most-used window across every service shown.
            let candidates = states.filter { $0.snapshot != nil }.flatMap { p in [(p, p.fiveHour), (p, p.weekly)] }
            if let (p, m) = candidates.max(by: { $0.1.used < $1.1.used }) {
                return make([Segment(provider: p.provider, outer: m.fraction(display), inner: nil,
                                     outerColor: NSColor(m.colors[1]), innerColor: .clear,
                                     text: (m.kind == .weekly ? "週" : "") + "\(m.value(display))%", dimmed: dimmed(p))])
            }
            fallthrough
        case .session, .both, .iconOnly:
            return make(states.map { p in
                let f = p.fiveHour, w = p.weekly
                let text: String
                switch style {
                case .session: text = p.snapshot == nil ? "–" : "\(f.value(display))%"
                case .both: text = p.snapshot == nil ? "–" : "\(f.value(display))%·\(w.value(display))%"
                default: text = ""
                }
                return Segment(provider: p.provider, outer: f.fraction(display), inner: single ? w.fraction(display) : nil,
                               outerColor: NSColor(f.colors[1]), innerColor: NSColor(w.colors[1]),
                               text: text, dimmed: dimmed(p))
            })
        }
    }
}

@MainActor
final class StatusController: NSObject, NSPopoverDelegate {
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let store: UsageStore
    private let settings: Settings
    private let widget: WidgetController
    private let popover = NSPopover()

    init(store: UsageStore, settings: Settings, widget: WidgetController) {
        self.store = store
        self.settings = settings
        self.widget = widget
        super.init()
        item.button?.imagePosition = .imageOnly
        item.button?.target = self
        item.button?.action = #selector(statusClicked)
        item.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])

        let panel = NSHostingController(rootView: ControlPanel(store: store, settings: settings,
                                                               raiseWidget: { [weak widget] in widget?.raise() }))
        panel.sizingOptions = [.preferredContentSize]
        popover.contentViewController = panel
        popover.behavior = .semitransient
        popover.animates = true
        popover.delegate = self

        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(accessibilityChanged),
            name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil)
        update()
    }

    private enum Activity { case still, idle, loading }
    private var activity = Activity.still
    private var animationTimer: Timer?
    private var animationStep = 0
    private var pose = StatusIcon.CharacterPose.resting

    deinit {
        animationTimer?.invalidate()
        NSWorkspace.shared.notificationCenter.removeObserver(self)
    }

    @objc private func accessibilityChanged(_ notification: Notification) { update() }

    func update() {
        let states = store.states(settings, providers: settings.menuBarProviders)
        let claude = states.first { $0.provider == .claude }
        let next: Activity
        if !settings.menuBarMode.isCharacter || NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            next = .still
        } else if claude?.loading == true {
            next = .loading
        } else if let claude, claude.snapshot != nil, claude.error == nil || claude.softError {
            next = .idle
        } else {
            next = .still
        }
        if next != activity {
            animationTimer?.invalidate()
            animationTimer = nil
            activity = next
            animationStep = 0
            pose = .resting
            scheduleAnimation()
        }
        render()
        item.button?.toolTip = store.states(settings, providers: settings.activeProviders).map { p in
            "\(p.provider.name) — 5時間 \(p.fiveHour.used)% ・ 週間 \(p.weekly.used)% 使用" + (p.error.map { "（\($0)）" } ?? "")
        }.joined(separator: "\n")
    }

    /// One-shot idle timers avoid continuous redraws between the occasional blinks.
    private func scheduleAnimation() {
        guard activity != .still else { return }
        let delay: TimeInterval = activity == .loading ? 0.12 : (pose.eyesClosed ? 0.14 : 7)
        let timer = Timer(timeInterval: delay, repeats: false) { [weak self] timer in
            Task { @MainActor in
                guard let self, self.animationTimer === timer else { return }
                self.animationTimer = nil
                switch self.activity {
                case .loading:
                    self.pose = StatusIcon.CharacterPose.loading[self.animationStep]
                    self.animationStep = (self.animationStep + 1) % StatusIcon.CharacterPose.loading.count
                case .idle:
                    self.pose = self.pose.eyesClosed ? .resting : .blink
                case .still:
                    return
                }
                self.render()
                self.scheduleAnimation()
            }
        }
        timer.tolerance = delay > 1 ? 0.5 : 0.01
        animationTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func render() {
        guard let button = item.button else { return }
        let states = store.states(settings, providers: settings.menuBarProviders)
        button.image = StatusIcon.image(for: states, style: settings.menuBarMode, display: settings.displayMode,
                                        characterColor: settings.characterColor, pose: pose)
        button.title = ""
    }

    @objc private func statusClicked(_ sender: NSStatusBarButton) {
        if popover.isShown { popover.performClose(nil) } else { showPanel(from: sender) }
    }

    func showPanelFromMenuBar() {
        guard let button = item.button else { return }
        showPanel(from: button)
    }

    /// Shows the panel under the menu bar icon, or beside the widget when opened from there.
    func showPanel(from view: NSView) {
        if popover.isShown { popover.performClose(nil) }
        store.refreshIfStale(300)
        NSApp.activate()
        let edge: NSRectEdge = view is NSStatusBarButton ? .minY : .minX
        popover.show(relativeTo: view.bounds, of: view, preferredEdge: edge)
        popover.contentViewController?.view.window?.makeKey()
    }
}

// MARK: - App

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let store = UsageStore.shared
    private let settings = Settings.shared
    private var widget: WidgetController!
    private var status: StatusController!
    private var bag = Set<AnyCancellable>()

    func applicationDidFinishLaunching(_ notification: Notification) {
        widget = WidgetController(store: store, settings: settings)
        status = StatusController(store: store, settings: settings, widget: widget)
        widget.contextHandler = { [weak self] view in self?.status.showPanel(from: view) }
        WorkActivityStore.shared.watchChatGPT = { Settings.shared.detectChatGPTApp }
        // `--show-panel [settings]` opens the panel at launch (handy for screenshots).
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--show-panel") {
            if args.indices.contains(i + 1), args[i + 1] == "settings" { PanelState.shared.tab = .settings }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in self?.status.showPanelFromMenuBar() }
        }
        widget.apply()
        store.start()
        updateActivityMonitoring()

        settings.objectWillChange
            .sink { [weak self] _ in
                DispatchQueue.main.async {
                    self?.widget.apply()
                    self?.status.update()
                    self?.store.reschedule()
                    self?.store.refreshMissing()   // e.g. a service was just switched on
                    self?.updateActivityMonitoring()
                }
            }
            .store(in: &bag)
        store.objectWillChange
            .sink { [weak self] _ in
                DispatchQueue.main.async {
                    self?.status.update()
                    self?.widget.fit()
                }
            }
            .store(in: &bag)
    }

    private func updateActivityMonitoring() {
        if settings.showWidget && settings.showWorkScene { WorkActivityStore.shared.start() }
        else { WorkActivityStore.shared.stop() }
    }

    func applicationWillTerminate(_ notification: Notification) { WorkActivityStore.shared.stop() }
}

@main
enum Main {
    @MainActor
    static func main() {
        signal(SIGPIPE, SIG_IGN)   // a codex child that exits early must not take us down
        let args = CommandLine.arguments
        if args.count >= 3, args[1] == "--icon" { DevTools.renderIconset(to: args[2]); return }
        if args.count >= 3, args[1] == "--render" { DevTools.renderPreviews(to: args[2]); return }
        if args.count >= 2, args[1] == "--dump" { DevTools.dump(); return }
        if args.contains("--offline") { UsageStore.offline = true }
        if args.count >= 2, args[1] == "--chatgpt" {
            // Development check: what the ChatGPT watcher sees, every 2 seconds.
            let rounds = args.count >= 3 ? Int(args[2]) ?? 10 : 10
            for _ in 0..<rounds {
                let start = Date()
                let state = ChatGPTWatcher.check()
                print(Fmt.format(Date(), "HH:mm:ss"), state, String(format: "(%.0f ms)", Date().timeIntervalSince(start) * 1000))
                Thread.sleep(forTimeInterval: 2)
            }
            return
        }
        if args.count >= 2, args[1] == "--test-cli" { DevTools.testCLIRefresh(); return }
        if args.count >= 3, args[1] == "--menubar" { DevTools.renderMenuBarStyles(to: args[2]); return }
        if args.count >= 3, args[1] == "--character" { DevTools.renderCharacter(to: args[2]); return }
        if args.count >= 3, args[1] == "--character-animation" { DevTools.renderCharacterAnimation(to: args[2]); return }
        if args.count >= 3, args[1] == "--work-scenes" { DevTools.renderWorkScenes(to: args[2]); return }
        if args.count >= 2, args[1] == "--activity" { DevTools.dumpActivity(); return }

        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        withExtendedLifetime(delegate) { app.run() }
    }
}
