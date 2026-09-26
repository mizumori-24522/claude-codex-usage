import AppKit
import SwiftUI

/// Build-time helpers: `--icon <dir>` writes the iconset, `--render <dir>` writes card previews,
/// `--dump` fetches once and prints the numbers (never the token), `--test-cli` exercises the token refresh.
@MainActor
enum DevTools {
    static func renderIconset(to dir: String) {
        let url = URL(fileURLWithPath: dir)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        for base in [16, 32, 128, 256, 512] {
            for scale in [1, 2] {
                let px = base * scale
                let name = scale == 1 ? "icon_\(base)x\(base).png" : "icon_\(base)x\(base)@2x.png"
                write(AppIconView(), scale: CGFloat(px) / 1024, to: url.appendingPathComponent(name))
            }
        }
    }

    static func renderPreviews(to dir: String) {
        let url = URL(fileURLWithPath: dir)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        let now = Date()
        func state(_ p: Provider, _ s: UsageSnapshot?, mode: DisplayMode = .used, color: ColorMode = .level) -> ProviderState {
            ProviderState(provider: p, snapshot: s, error: nil, loading: false, stale: false, now: now, mode: mode, colorMode: color)
        }
        let claude = UsageStore.shared[.claude].snapshot ?? sample(.claude, five: 51, week: 21)
        let codex = UsageStore.shared[.codex].snapshot ?? sample(.codex, five: 0, week: 55)

        for dark in [false, true] {
            let both = [state(.claude, claude), state(.codex, codex)]
            board(dark: dark, name: "dual", url: url) {
                AnyView(DualSmallCard(items: both))
                AnyView(DualMediumCard(items: both))
                AnyView(LargeCard(items: both))
            }
        }

        // Colour steps: one card per level, from 水色 to 赤.
        let steps: [(Double, Double)] = [(8, 12), (30, 34), (50, 55), (67, 70), (82, 85), (95, 97)]
        for mode in DisplayMode.allCases {
            board(dark: false, name: "levels-\(mode.rawValue)", url: url) {
                for (f, w) in steps { AnyView(SmallCard(p: state(.claude, sample(.claude, five: f, week: w), mode: mode))) }
            }
        }
        board(dark: false, name: "large", url: url) {
            AnyView(MediumCard(p: state(.claude, claude, mode: .remaining)))
            AnyView(LargeCard(items: [state(.claude, claude, mode: .remaining), state(.codex, codex, mode: .remaining)])
                .magnified(WidgetSize.largeScale))
        }
        board(dark: false, name: "brand", url: url) {
            AnyView(DualMediumCard(items: [state(.claude, claude, color: .brand), state(.codex, codex, color: .brand)]))
            AnyView(DualMediumCard(items: [state(.claude, claude, mode: .remaining), state(.codex, codex, mode: .remaining)]))
        }
    }

    private static func board(dark: Bool, name: String, url: URL, @ArrayBuilder _ cards: () -> [AnyView]) {
        let list = cards()
        let view = HStack(alignment: .top, spacing: 24) {
            ForEach(list.indices, id: \.self) { i in
                list[i]
                    .background(RoundedRectangle(cornerRadius: 24, style: .continuous)
                        .fill(dark ? Color.black.opacity(0.5) : Color.white.opacity(0.62)))
                    .overlay(RoundedRectangle(cornerRadius: 24, style: .continuous)
                        .strokeBorder(Color.white.opacity(dark ? 0.12 : 0.5), lineWidth: 1))
            }
        }
        .padding(32)
        .background(LinearGradient(colors: [Color(hex: 0x6FA8DC), Color(hex: 0x9CC7E8), Color(hex: 0x4E7D5B)],
                                   startPoint: .top, endPoint: .bottom))
        .environment(\.colorScheme, dark ? .dark : .light)
        write(view, scale: 2, to: url.appendingPathComponent("preview-\(name)\(dark ? "-dark" : "").png"))
    }

    /// Every menu bar style side by side, on a light and a dark menu bar, at 2x.
    static func renderMenuBarStyles(to path: String) {
        let now = Date()
        let display = Settings.shared.displayMode
        func state(_ p: Provider) -> ProviderState {
            let s = UsageStore.shared[p].snapshot ?? sample(p, five: p == .claude ? 20 : 0, week: p == .claude ? 24 : 55)
            return ProviderState(provider: p, snapshot: s, error: nil, loading: false, stale: false,
                                 now: now, mode: display, colorMode: Settings.shared.colorMode)
        }
        let groups: [(String, [ProviderState])] = [("Claude と Codex", [state(.claude), state(.codex)]),
                                                    ("Claude のみ", [state(.claude)])]
        let rowH: CGFloat = 38, labelW: CGFloat = 250, colW: CGFloat = 170, headH: CGFloat = 30
        let modes = MenuBarMode.allCases
        let size = NSSize(width: labelW + colW * CGFloat(groups.count * 2), height: headH + rowH * CGFloat(modes.count))
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * 2), pixelsHigh: Int(size.height * 2),
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return }
        rep.size = size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSColor.white.setFill()
        NSRect(origin: .zero, size: size).fill()
        let labelAttrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 13, weight: .medium), .foregroundColor: NSColor.black]
        let headAttrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 11, weight: .semibold), .foregroundColor: NSColor.darkGray]
        for (g, group) in groups.enumerated() {
            for (j, name) in ["ライト", "ダーク"].enumerated() {
                let x = labelW + colW * CGFloat(g * 2 + j)
                ("\(group.0)・\(name)" as NSString).draw(at: NSPoint(x: x + 12, y: size.height - headH + 9), withAttributes: headAttrs)
            }
        }
        for (i, mode) in modes.enumerated() {
            let y = size.height - headH - rowH * CGFloat(i + 1)
            (mode.label as NSString).draw(at: NSPoint(x: 14, y: y + 11), withAttributes: labelAttrs)
            for (g, group) in groups.enumerated() {
                for (j, appearance) in [NSAppearance.Name.aqua, .darkAqua].enumerated() {
                    let cell = NSRect(x: labelW + colW * CGFloat(g * 2 + j), y: y + 3, width: colW - 6, height: rowH - 6)
                    NSAppearance(named: appearance)!.performAsCurrentDrawingAppearance {
                        (j == 0 ? NSColor(white: 0.9, alpha: 1) : NSColor(white: 0.17, alpha: 1)).setFill()
                        NSBezierPath(roundedRect: cell, xRadius: 6, yRadius: 6).fill()
                        let img = StatusIcon.image(for: group.1, style: mode, display: display,
                                                   characterColor: Settings.shared.characterColor)
                        img.draw(in: NSRect(x: cell.minX + 12, y: cell.midY - img.size.height / 2,
                                            width: img.size.width, height: img.size.height))
                    }
                }
            }
        }
        NSGraphicsContext.restoreGraphicsState()
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
    }

    /// The pixel character at several usage levels, for both colour options, light and dark.
    static func renderCharacter(to path: String) {
        let now = Date()
        let display = Settings.shared.displayMode
        let used: [Double] = [5, 30, 50, 67, 82, 95]
        let options = CharacterColor.allCases
        let cellW: CGFloat = 132, cellH: CGFloat = 44, labelW: CGFloat = 230, headH: CGFloat = 28
        let rowsCount = options.count * 2 * 2   // option × style × appearance
        let size = NSSize(width: labelW + cellW * CGFloat(used.count), height: headH + cellH * CGFloat(rowsCount))
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * 2), pixelsHigh: Int(size.height * 2),
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return }
        rep.size = size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSColor.white.setFill()
        NSRect(origin: .zero, size: size).fill()
        let label: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 12, weight: .medium), .foregroundColor: NSColor.black]
        let head: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 11, weight: .semibold), .foregroundColor: NSColor.darkGray]
        for (j, u) in used.enumerated() {
            let v = display == .used ? Int(u) : 100 - Int(u)
            ("\(display == .used ? "使用" : "残り") \(v)%" as NSString)
                .draw(at: NSPoint(x: labelW + cellW * CGFloat(j) + 12, y: size.height - headH + 8), withAttributes: head)
        }
        var row = 0
        for option in options {
            for style in [MenuBarMode.character, .characterNumbers] {
                for appearance in [NSAppearance.Name.aqua, .darkAqua] {
                    let y = size.height - headH - cellH * CGFloat(row + 1)
                    let text = "\(option == .level ? "使用率で変化" : "オレンジ")・\(style == .character ? "キャラのみ" : "＋数字")・\(appearance == .aqua ? "ライト" : "ダーク")"
                    (text as NSString).draw(at: NSPoint(x: 12, y: y + 14), withAttributes: label)
                    for (j, u) in used.enumerated() {
                        let snap = sample(.claude, five: u, week: min(100, u + 8))
                        let st = ProviderState(provider: .claude, snapshot: snap, error: nil, loading: false, stale: false,
                                               now: now, mode: display, colorMode: Settings.shared.colorMode)
                        let cell = NSRect(x: labelW + cellW * CGFloat(j), y: y + 3, width: cellW - 6, height: cellH - 6)
                        NSAppearance(named: appearance)!.performAsCurrentDrawingAppearance {
                            (appearance == .aqua ? NSColor(white: 0.9, alpha: 1) : NSColor(white: 0.17, alpha: 1)).setFill()
                            NSBezierPath(roundedRect: cell, xRadius: 6, yRadius: 6).fill()
                            let img = StatusIcon.image(for: [st], style: style, display: display, characterColor: option)
                            img.draw(in: NSRect(x: cell.minX + 14, y: cell.midY - img.size.height / 2,
                                                width: img.size.width, height: img.size.height))
                        }
                    }
                    row += 1
                }
            }
        }
        NSGraphicsContext.restoreGraphicsState()
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
    }

    static func dump() {
        final class Flag { var done = false }
        let flag = Flag()
        Task { @MainActor in
            let (claude, ranCLI) = await ClaudeAPI.load(allowCLI: true)
            let codex = await CodexRPC.load()
            for (name, result) in [("claude", claude), ("codex", codex)] {
                switch result {
                case .success(let s):
                    print("[\(name)] plan:", s.plan ?? "-")
                    print("  5h:", s.fiveHour.map { "\($0.utilization)% resets \($0.resetsAt.map { "\($0)" } ?? "-")" } ?? "-")
                    print("  7d:", s.sevenDay.map { "\($0.utilization)% resets \($0.resetsAt.map { "\($0)" } ?? "-")" } ?? "-")
                    if let c = s.credit { print("  credit:", "\(c.remaining)/\(c.limit)") }
                    if let n = s.resetCredits { print("  reset credits:", n) }
                case .failure(let e):
                    print("[\(name)] error:", (e as? LocalizedError)?.errorDescription ?? "\(e)")
                }
            }
            print("ranCLI:", ranCLI)
            flag.done = true
        }
        while !flag.done { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
    }

    static func testCLIRefresh() {
        let before = (try? CredentialStore.load())?.expiresAt
        do {
            try CLIRefresher.refresh()
            let after = (try? CredentialStore.load())?.expiresAt
            print("cli ok; expiry before:", before.map { "\($0)" } ?? "-", "after:", after.map { "\($0)" } ?? "-")
        } catch {
            print("cli error:", (error as? LocalizedError)?.errorDescription ?? "\(error)")
        }
    }

    private static func write<V: View>(_ view: V, scale: CGFloat, to url: URL) {
        let r = ImageRenderer(content: view)
        r.scale = scale
        guard let cg = r.cgImage,
              let png = NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:]) else { return }
        try? png.write(to: url)
    }

    private static func sample(_ p: Provider, five: Double, week: Double) -> UsageSnapshot {
        let now = Date()
        var s = UsageSnapshot(fiveHour: UsageWindow(utilization: five, resetsAt: now.addingTimeInterval(p == .claude ? 18 * 60 : 4.8 * 3600)),
                              sevenDay: UsageWindow(utilization: week, resetsAt: now.addingTimeInterval(42 * 3600)),
                              plan: p == .claude ? "Pro" : "Plus", fetchedAt: now)
        if p == .claude {
            s.credit = CreditInfo(limit: 100, remaining: 100, expiresAt: now.addingTimeInterval(40 * 86400))
            s.breakdown = [BreakdownRow(id: "claude_code", name: "Claude Code", percent: 96),
                           BreakdownRow(id: "chat", name: "チャット", percent: 4)]
        } else {
            s.resetCredits = 1
        }
        return s
    }
}

@resultBuilder
enum ArrayBuilder {
    static func buildExpression(_ v: AnyView) -> [AnyView] { [v] }
    static func buildBlock(_ parts: [AnyView]...) -> [AnyView] { parts.flatMap { $0 } }
    static func buildArray(_ parts: [[AnyView]]) -> [AnyView] { parts.flatMap { $0 } }
}

struct AppIconView: View {
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 186, style: .continuous)
                .fill(LinearGradient(colors: [Color(hex: 0x34302D), Color(hex: 0x171514)], startPoint: .top, endPoint: .bottom))
                .overlay(RoundedRectangle(cornerRadius: 186, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.08), lineWidth: 4))
                .frame(width: 824, height: 824)
                .shadow(color: .black.opacity(0.35), radius: 18, y: 10)
            RingGauge(progress: 0.68, lineWidth: 70, colors: Palette.green).frame(width: 610, height: 610)
            RingGauge(progress: 0.4, lineWidth: 70, colors: Palette.sky).frame(width: 450, height: 450)
            ClaudeSpark().frame(width: 200, height: 200)
        }
        .frame(width: 1024, height: 1024)
    }
}
