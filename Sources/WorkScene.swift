import SwiftUI

enum WorkSceneTileColors { static let blue = Color(hex: 0x3B82F6) }

/// Whether anyone can see the widget. A desktop-level widget spends most of its life behind
/// other windows, and animating it there only costs power.
@MainActor
final class SceneVisibility: ObservableObject {
    static let shared = SceneVisibility()
    @Published var visible = true
}

/// Body colours for a character: `[light, body, shade]`.
struct CharacterTint: Equatable {
    var light: Color
    var body: Color
    var shade: Color

    init(_ ramp: [Color]) { light = ramp[0]; body = ramp[1]; shade = ramp[2] }

    static let codex = CharacterTint([Color(hex: 0xB9B0FA), Palette.codexAccent, Color(hex: 0x5B4BD6)])

    /// Claude follows its 5-hour level on its own editable scale, exactly like the menu bar
    /// character; Codex keeps its own colour.
    @MainActor
    static func `for`(_ p: ProviderState, option: CharacterColor, steps: [CharacterStep]? = nil) -> CharacterTint {
        guard p.provider == .claude else { return .codex }
        guard p.snapshot != nil else { return CharacterTint(Palette.claude) }
        let used = p.fiveHour.used
        if option == .claude { return CharacterTint(Level(used: used) == .critical ? Palette.red : Palette.claude) }
        return CharacterTint(CharacterScale.ramp(CharacterScale.hex(forUsed: used, in: steps ?? Settings.shared.characterSteps)))
    }
}

/// A quiet workbench under the usage gauges. The monitor alone selects the work phase.
struct WorkSceneFooter: View {
    var providers: [Provider]
    var states: [Provider: WorkActivity]
    var tints: [Provider: CharacterTint] = [:]
    var style: WorkSceneStyle = .desk
    var compact = false
    /// A fixed clock for image/GIF previews; never used to manufacture live activity.
    var previewDate: Date? = nil
    /// Free resets left per service, shown as 🎫 beside the character.
    var tickets: [Provider: ResetTickets] = [:]

    var body: some View {
        VStack(spacing: 0) {
            Rectangle().fill(.primary.opacity(0.08)).frame(height: 1)
            HStack(alignment: .top, spacing: compact ? 2 : 12) {
                ForEach(providers) { provider in
                    WorkSceneTile(provider: provider,
                                  activity: states[provider] ?? WorkActivity(phase: .unknown, sessionCount: 0,
                                                                           detail: "作業状態をまだ検出していません", changedAt: .distantPast),
                                  tint: tints[provider] ?? (provider == .claude ? CharacterTint(Palette.claude) : .codex),
                                  style: style, compact: compact, previewDate: previewDate,
                                  tickets: tickets[provider])
                    .frame(maxWidth: .infinity)
                }
            }
            .padding(.horizontal, compact ? 8 : 14)
            .padding(.top, 5)
            .padding(.bottom, 9)
        }
        .frame(height: compact ? 76 : 96)
    }
}

private struct WorkSceneTile: View {
    var provider: Provider
    var activity: WorkActivity
    var tint: CharacterTint
    var style: WorkSceneStyle
    var compact: Bool
    var previewDate: Date?
    var tickets: ResetTickets? = nil
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ObservedObject private var visibility = SceneVisibility.shared

    static let unseenBlue = WorkSceneTileColors.blue
    private var unseen: Date? { activity.pendingCompletion }

    private var label: String {
        if let unseen { return "完了 \(Fmt.format(unseen, "H:mm"))" }
        switch activity.phase {
        case .working: return "作業中"
        case .waiting: return "確認待ち"
        case .finished: return "完了"
        case .idle: return "待機中"
        case .unknown: return "未検出"
        }
    }

    private var indicator: Color {
        if unseen != nil { return Self.unseenBlue }
        switch activity.phase {
        case .working, .finished: return tint.body
        case .waiting: return PixelWorkbench.amber
        case .idle, .unknown: return .secondary.opacity(0.5)
        }
    }

    private var status: some View {
        HStack(spacing: 3) {
            Circle().fill(indicator).frame(width: 4, height: 4)
            Text(label)
                .font(.system(size: compact ? 8.5 : 9.5, weight: .medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            if activity.sessionCount > 1 {
                Text("\(activity.sessionCount)")
                    .font(.system(size: compact ? 8 : 9, weight: .semibold, design: .rounded))
                    .foregroundStyle(indicator)
                    .monospacedDigit()
            }
        }
        .fixedSize()
    }

    var body: some View {
        VStack(spacing: compact ? 2 : 3) {
            if let previewDate {
                scene(at: previewDate)
            } else {
                TimelineView(WorkSceneSchedule(phase: activity.phase, changedAt: activity.changedAt,
                                              reducedMotion: reduceMotion || !visibility.visible,
                                              blinkOffset: provider == .claude ? 0 : 3,
                                              waving: unseen != nil)) { clock in
                    scene(at: clock.date)
                }
            }
            if compact {
                Text(provider.name).font(.system(size: 9, weight: .semibold))
                status
            } else {
                HStack(spacing: 7) {
                    Text(provider.name).font(.system(size: 10, weight: .semibold))
                    status
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(provider.name)、\(label)\(tickets.map { "、無料リセット\($0.count)回" } ?? "")\(unseen != nil ? "、未確認" : "")\(activity.sessionCount > 1 ? "、\(activity.sessionCount)セッション" : "")")
        .help(activity.detail + (tickets.map { t in
            "\n🎫 無料リセット あと\(t.count)回" + (t.nextExpiry.map { "（次の期限 \(Fmt.format($0, "M/d H:mm"))）" } ?? "")
        } ?? ""))
    }

    @ViewBuilder private func scene(at date: Date) -> some View {
        Group {
            if style == .laptop {
                LaptopWorkbench(provider: provider, phase: activity.phase, tint: tint, unseen: unseen != nil, date: date,
                                changedAt: activity.changedAt, reduceMotion: reduceMotion)
            } else {
                PixelWorkbench(provider: provider, phase: activity.phase, tint: tint, unseen: unseen != nil, date: date,
                               changedAt: activity.changedAt, reduceMotion: reduceMotion)
            }
        }
            .frame(height: compact ? 36 : 60)
            .accessibilityHidden(true)
            .overlay(alignment: .topLeading) {
                if let tickets { TicketBadge(tickets: tickets, compact: compact).offset(y: compact ? -2 : 2) }
            }
    }
}

/// Continuous redraws are limited to real work. Resting characters wake twice every seven
/// seconds to blink; the celebration produces one finite burst and then stops scheduling.
private struct WorkSceneSchedule: TimelineSchedule {
    var phase: WorkPhase
    var changedAt: Date
    var reducedMotion: Bool
    var blinkOffset: Double
    var waving = false

    func entries(from startDate: Date, mode: Mode) -> AnySequence<Date> {
        guard !reducedMotion, phase != .unknown || waving else { return AnySequence([startDate]) }
        if waving && phase != .working && phase != .waiting && phase != .finished {
            // Frames only for the brief wave (1.2 s every 6 s); the rest of the time is still.
            return AnySequence {
                var next = startDate
                return AnyIterator<Date> {
                    defer {
                        let t = next.timeIntervalSinceReferenceDate
                        let cycleStart = floor(t / PixelWorkbench.waveCycle) * PixelWorkbench.waveCycle
                        let within = t - cycleStart
                        let following = within < PixelWorkbench.waveLength - 1e-6
                            ? t + PixelWorkbench.waveStep : cycleStart + PixelWorkbench.waveCycle
                        next = Date(timeIntervalSinceReferenceDate: max(following, t + 0.05))
                    }
                    return next
                }
            }
        }
        if phase == .finished {
            let end = changedAt.addingTimeInterval(0.9)
            guard startDate < end else { return AnySequence([startDate]) }
            var dates = [startDate]
            var next = startDate.addingTimeInterval(0.10)
            while next < end {
                dates.append(next)
                next = next.addingTimeInterval(0.10)
            }
            dates.append(end)
            return AnySequence(dates)
        }
        if phase == .working {
            // The typing beat of the original scene: one hand taps, the code on screen scrolls.
            let step = mode == .lowFrequency ? PixelWorkbench.keystroke * 2 : PixelWorkbench.keystroke
            return AnySequence {
                var next = startDate
                return AnyIterator<Date> {
                    defer { next = next.addingTimeInterval(step) }
                    return next
                }
            }
        }
        return AnySequence {
            var first = true
            let time = startDate.timeIntervalSinceReferenceDate + blinkOffset
            let cycleStart = floor(time / 7) * 7
            let alreadyBlinking = time - cycleStart < 0.14
            // If this view appeared with its eyes closed, schedule their reopening first.
            var nextBlink = Date(timeIntervalSinceReferenceDate: cycleStart - blinkOffset + (alreadyBlinking ? 0 : 7))
            var closing = !alreadyBlinking
            return AnyIterator<Date> {
                if first { first = false; return startDate }
                let entry = closing ? nextBlink : nextBlink.addingTimeInterval(0.14)
                if !closing { nextBlink = nextBlink.addingTimeInterval(7) }
                closing.toggle()
                return entry
            }
        }
    }
}

/// Pixel-native workbench on a fixed 36 × 24 grid (the original prototype's scene).
/// The character faces you beside a desk; while working one hand types and the code scrolls.
/// Claude keeps its familiar silhouette; Codex gets an original terminal-shaped companion.
struct PixelWorkbench: View {
    var provider: Provider
    var phase: WorkPhase
    var tint: CharacterTint
    var unseen = false
    var date: Date
    var changedAt: Date
    var reduceMotion: Bool
    @Environment(\.colorScheme) private var colorScheme

    static let keystroke = 0.4   // unhurried: about 2.5 frames a second keeps the work scene light
    static let amber = Color(hex: 0xC89C4C)
    static let waveCycle = 6.0, waveLength = 1.2, waveStep = 0.2

    /// While a finished turn is unseen: waving now, and which of the two arm poses to show.
    static func wave(at time: TimeInterval, unseen: Bool, reduceMotion: Bool) -> (active: Bool, up: Bool) {
        guard unseen, !reduceMotion else { return (false, false) }
        let within = time.truncatingRemainder(dividingBy: waveCycle)
        return (within < waveLength, Int(within / waveStep) % 2 == 0)
    }

    /// The blue dot that marks an unseen result, like the unread dot in the Claude app.
    static func unseenDot(_ context: GraphicsContext, origin: CGPoint, unit: CGFloat, x: CGFloat, y: CGFloat) {
        let rect = CGRect(x: origin.x + x * unit, y: origin.y + y * unit, width: 2.4 * unit, height: 2.4 * unit)
        context.fill(Path(ellipseIn: rect.insetBy(dx: -0.6 * unit, dy: -0.6 * unit)), with: .color(.white.opacity(0.85)))
        context.fill(Path(ellipseIn: rect), with: .color(WorkSceneTileColors.blue))
    }

    private static let claude = [
        "..############..", "..############..", "..##o######o##..", "..##o######o##..",
        "################", "################", "..############..", "..############..",
        "...#.#....#.#...", "...#.#....#.#..."
    ]
    private static let codex = [
        "..############..", ".##############.", ".##oooooooooo##.", ".##oooooooooo##.",
        ".##oooooooooo##.", ".##############.", "################", "..############..",
        "...##......##...", "...##......##..."
    ]

    var body: some View {
        Canvas { context, size in
            let unit = max(0.5, (min(size.width / 36, size.height / 24) * 2).rounded(.down) / 2)
            let origin = CGPoint(x: ((size.width - 36 * unit) / 2 * 2).rounded() / 2,
                                 y: size.height - 24 * unit)
            let dark = colorScheme == .dark
            // The character's colour: Claude follows its level, Codex its own violet.
            let accent = Color(nsColor: CharacterScale.legible(NSColor(tint.body), onDark: dark))
            let desk = Color.primary.opacity(dark ? 0.22 : 0.19)
            let terminal = dark ? Color(hex: 0x292C36) : Color(hex: 0x3E424D)
            let time = date.timeIntervalSinceReferenceDate
            let working = phase == .working
            let frame = reduceMotion ? 0 : Int(floor(time / Self.keystroke))
            let elapsed = date.timeIntervalSince(changedAt)
            let hop = !reduceMotion && phase == .finished && elapsed >= 0 && elapsed < 0.9
                ? (sin(elapsed / 0.9 * .pi) * 3).rounded() : 0
            let lift = CGFloat(hop + (working && !reduceMotion && frame % 6 >= 3 ? 1 : 0))
            let blinkTime = (time + (provider == .claude ? 0 : 3)).truncatingRemainder(dividingBy: 7)
            let blinking = !reduceMotion && phase != .unknown && blinkTime >= 0 && blinkTime < 0.14

            func pixel(_ x: CGFloat, _ y: CGFloat, _ width: CGFloat = 1, _ height: CGFloat = 1, _ color: Color) {
                let rect = CGRect(x: origin.x + x * unit, y: origin.y + y * unit,
                                  width: width * unit, height: height * unit)
                context.fill(Path(rect), with: .color(color), style: FillStyle(eoFill: false, antialiased: false))
            }

            // The furniture and text never move, so animation does not shift the card.
            pixel(1, 22, 34, 0.5, .primary.opacity(0.10))
            pixel(17, 19, 18, 1, desk)
            pixel(18, 20, 1, 2, desk)
            pixel(33, 20, 1, 2, desk)
            pixel(22, 8, 11, 9, desk)
            pixel(23, 9, 9, 7, terminal)
            pixel(20, 17, 14, 1, desk)
            pixel(19, 18, 16, 1, desk)
            pixel(22, 18, 9, 0.5, .primary.opacity(0.18))

            // While working the screen breathes softly and spills a little light (from the laptop scene).
            if working {
                let glow = reduceMotion ? 1.0 : 0.5 + 0.5 * sin(time * 2 * .pi / 1.6)
                let light = tint.light
                pixel(23, 9, 9, 7, light.opacity(0.10 + 0.14 * glow))
                pixel(22, 7.5, 11, 0.5, light.opacity(0.22 * glow))
                pixel(21.5, 8, 0.5, 9, light.opacity(0.16 * glow))
                pixel(33, 8, 0.5, 9, light.opacity(0.16 * glow))
                pixel(22, 17, 11, 0.5, light.opacity(0.24 * glow))
            }

            let code = accent.opacity(working ? 0.85 : 0.36)
            if phase == .finished {
                pixel(26, 12, 1, 1, accent)
                pixel(27, 13, 1, 1, accent)
                pixel(28, 12, 1, 1, accent)
                pixel(29, 11, 1, 1, accent)
            } else {
                let scroll = working && !reduceMotion ? CGFloat(frame % 3) : 0
                pixel(24, 10, 3 + scroll, 0.5, code)
                pixel(24, 12, 5 - scroll, 0.5, code)
                pixel(24, 14, 2, 0.5, code)
                if working && (reduceMotion || frame % 4 < 2) { pixel(27, 14, 1, 0.5, accent) }
            }

            let rows = provider == .claude ? Self.claude : Self.codex
            let bodyColor = accent.opacity(phase == .unknown ? 0.48 : 1)
            let wave = Self.wave(at: time, unseen: unseen && !working, reduceMotion: reduceMotion)
            for (row, line) in rows.enumerated() {
                for (column, mark) in line.enumerated() where mark != "." {
                    // The outer arm lifts to wave; its resting cells stay empty meanwhile.
                    if wave.active && (provider == .claude ? (row == 4 || row == 5) && column <= 1 : row == 6 && column == 0) { continue }
                    let x = CGFloat(column + 1), y = CGFloat(row + 11) - lift
                    pixel(x, y, 1, 1, bodyColor)
                    if mark == "o" {
                        if provider == .claude {
                            if !blinking || row == 3 { pixel(x, y + (blinking ? 0.5 : 0), 1, blinking ? 0.5 : 1, Color(hex: 0x25201E)) }
                        } else {
                            pixel(x, y, 1, 1, terminal)
                        }
                    }
                }
            }
            if provider == .codex {
                // A >_ expression identifies the terminal companion without borrowing a mascot.
                pixel(5, 13 - lift, 1, 1, .white.opacity(0.9))
                pixel(6, 14 - lift, 1, 1, .white.opacity(0.9))
                pixel(5, 15 - lift, 1, 1, .white.opacity(0.9))
                if !blinking { pixel(10, 15 - lift, 3, 0.5, .white.opacity(0.9)) }
            }

            if wave.active {
                let arm: [(CGFloat, CGFloat)] = provider == .claude
                    ? (wave.up ? [(0, 1), (1, 1), (0, 2), (1, 2), (0, 3), (1, 3)]
                               : [(-2, 1), (-1, 1), (-1, 2), (0, 2), (0, 3), (1, 3)])
                    : (wave.up ? [(-1, 3), (0, 3), (-1, 4), (0, 4), (0, 5)]
                               : [(-3, 3), (-2, 3), (-2, 4), (-1, 4), (0, 5)])
                for (c, r) in arm { pixel(c + 1, r + 11 - lift, 1, 1, bodyColor) }
            }
            if unseen && !working { Self.unseenDot(context, origin: origin, unit: unit, x: 13.2, y: 7.2) }

            if working {
                // One hand reaches over to the keyboard and taps.
                let hand = reduceMotion ? CGFloat(0) : CGFloat(frame % 2)
                pixel(16, 16 - lift, 2, 1, bodyColor)
                pixel(17, 17 + hand, 2, 1, bodyColor)
                pixel(20, 17 + (1 - hand), 2, 1, bodyColor)
            }
            if phase == .waiting {
                pixel(17, 8, 1, 3, Self.amber)
                pixel(17, 12, 1, 1, Self.amber)
            }
            if phase == .finished && hop > 0 {
                pixel(6, 8, 1, 1, accent.opacity(0.65))
                pixel(14, 7, 1, 1, accent.opacity(0.65))
            }
        }
    }
}

/// The alternative scene: side-on at a laptop on a low desk, tapping calmly while the screen
/// glows. Same 36 × 24 grid as the desk scene so both fit the same space.
struct LaptopWorkbench: View {
    var provider: Provider
    var phase: WorkPhase
    var tint: CharacterTint
    var unseen = false
    var date: Date
    var changedAt: Date
    var reduceMotion: Bool
    @Environment(\.colorScheme) private var colorScheme

    // '#' body, 'S' shade (the far side, turned away), 'o' eye/face, 'A' the typing arm.
    private static let claudeFront = [
        "..############..", "..############..", "..##o######o##..", "..##o######o##..",
        "################", "################", "..############..", "..############..",
        "...#.#....#.#...", "...#.#....#.#..."
    ]
    private static let claudeSide = [
        "...##########SS.", "...##########SS.", "...#o###o####SS.", "...#o###o####SS.",
        ".AA##########SS.", ".AA##########SS.", "...##########SS.", "...##########SS.",
        "....#.#..#.#.S..", "....#.#..#.#.S.."
    ]
    private static let codexFront = [
        "..############..", ".##############.", ".##oooooooooo##.", ".##oooooooooo##.",
        ".##oooooooooo##.", ".##############.", "################", "..############..",
        "...##......##...", "...##......##..."
    ]
    private static let codexSide = [
        "...##########SS.", "..###########SS.", "..#ooooooo###SS.", "..#ooooooo###SS.",
        "..#ooooooo###SS.", ".AA##########SS.", "..###########SS.", "...##########SS.",
        "....##...##.S...", "....##...##.S..."
    ]
    private static let spriteX: CGFloat = 18, spriteY: CGFloat = 13
    private static let deskY: CGFloat = 20, keyboardY: CGFloat = 19

    var body: some View {
        Canvas { context, size in
            let unit = max(0.5, (min(size.width / 36, size.height / 24) * 2).rounded(.down) / 2)
            let origin = CGPoint(x: ((size.width - 36 * unit) / 2 * 2).rounded() / 2, y: size.height - 24 * unit)
            let dark = colorScheme == .dark
            let time = date.timeIntervalSinceReferenceDate
            let beat = reduceMotion ? 0 : Int(floor(time / PixelWorkbench.keystroke))
            let elapsed = date.timeIntervalSince(changedAt)

            func pixel(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat = 1, _ h: CGFloat = 1, _ color: Color) {
                let rect = CGRect(x: origin.x + x * unit, y: origin.y + y * unit, width: w * unit, height: h * unit)
                context.fill(Path(rect), with: .color(color), style: FillStyle(antialiased: false))
            }

            let unknown = phase == .unknown
            let body = unknown ? Color.secondary.opacity(0.45) : Color(nsColor: CharacterScale.legible(NSColor(tint.body), onDark: dark))
            let shade = unknown ? Color.secondary.opacity(0.35) : Color(nsColor: CharacterScale.legible(NSColor(tint.shade), onDark: dark))
            let eye = Color(hex: 0x25201E)
            let wood = dark ? Color(hex: 0x6B5A4B) : Color(hex: 0xB89878)
            let woodEdge = dark ? Color(hex: 0x54463A) : Color(hex: 0x9C7C5E)
            let laptop = dark ? Color(hex: 0x9AA1AD) : Color(hex: 0x7D8491)
            let laptopEdge = dark ? Color(hex: 0x767D89) : Color(hex: 0x626874)

            let typing = phase == .working
            let pressing = typing && !reduceMotion
            let glow = reduceMotion ? 1.0 : 0.75 + 0.25 * sin(time * 2 * .pi / 1.6)

            // Floor and low desk.
            pixel(0, 23, 36, 0.5, .primary.opacity(0.10))
            pixel(1, Self.deskY, 21, 1, wood)
            pixel(1, Self.deskY + 1, 21, 0.5, woodEdge)
            pixel(2, Self.deskY + 1, 1, 2, woodEdge)
            pixel(20, Self.deskY + 1, 1, 2, woodEdge)

            // Laptop: open while there is work or a question, closed when resting.
            let open = phase == .working || phase == .waiting || phase == .finished
            pixel(7, Self.keyboardY, 13, 1, laptop)
            if open {
                let screen: Color
                switch phase {
                case .working: screen = tint.light.opacity(glow)
                case .waiting: screen = PixelWorkbench.amber
                default: screen = Color(hex: 0x5BD38A)
                }
                for i in 0..<8 {
                    let x = 7 - CGFloat((i * 3) / 8), y = Self.keyboardY - 1 - CGFloat(i)
                    pixel(x - 1, y, 1, 1, laptopEdge)
                    pixel(x, y, 1, 1, screen)
                    if typing { pixel(x + 1, y, 1, 1, tint.light.opacity(0.22 * glow)) }
                }
                if pressing && beat % 2 == 0 {
                    pixel(9 + CGFloat((beat / 2 * 5) % 9), Self.keyboardY, 1, 0.5, tint.light)
                }
            } else {
                pixel(7, Self.keyboardY - 0.5, 13, 0.5, laptopEdge)
            }

            // Character: side-on while typing, facing you otherwise.
            let hop = !reduceMotion && phase == .finished && elapsed >= 0 && elapsed < 0.9
                ? CGFloat((sin(elapsed / 0.9 * .pi) * 3).rounded()) : 0
            let tapDown = pressing && beat % 2 == 0
            let bob: CGFloat = tapDown ? 0.5 : 0
            let blinkTime = (time + (provider == .claude ? 0 : 3)).truncatingRemainder(dividingBy: 7)
            let blinking = !reduceMotion && !unknown && !typing && blinkTime >= 0 && blinkTime < 0.14
            let rows = provider == .claude ? (typing ? Self.claudeSide : Self.claudeFront)
                                           : (typing ? Self.codexSide : Self.codexFront)
            let wave = PixelWorkbench.wave(at: time, unseen: unseen && !typing, reduceMotion: reduceMotion)
            for (r, line) in rows.enumerated() {
                for (c, mark) in line.enumerated() where mark != "." {
                    if wave.active && (provider == .claude ? (r == 4 || r == 5) && c >= 14 : r == 6 && c == 15) { continue }
                    let x = Self.spriteX + CGFloat(c)
                    var y = Self.spriteY + CGFloat(r) - hop + bob
                    switch mark {
                    case "S": pixel(x, y, 1, 1, shade)
                    case "A":
                        if tapDown { y += 1 }
                        pixel(x, y, 1, 1, body)
                    case "o":
                        pixel(x, y, 1, 1, body)
                        if provider == .claude {
                            if !blinking || r == 3 { pixel(x, y + (blinking ? 0.5 : 0), 1, blinking ? 0.5 : 1, eye) }
                        } else {
                            pixel(x, y, 1, 1, dark ? Color(hex: 0x292C36) : Color(hex: 0x3E424D))
                        }
                    default: pixel(x, y, 1, 1, body)
                    }
                }
            }
            if provider == .codex {
                let face = Color.white.opacity(unknown ? 0.5 : 0.9)
                let fx = Self.spriteX + (typing ? 3 : 4), fy = Self.spriteY - hop + bob
                pixel(fx, fy + 2, 1, 1, face)
                pixel(fx + 1, fy + 3, 1, 1, face)
                pixel(fx, fy + 4, 1, 1, face)
                if !blinking { pixel(fx + (typing ? 3 : 5), fy + 4.5, typing ? 2 : 3, 0.5, face) }
            }
            if wave.active {
                let arm: [(CGFloat, CGFloat)] = provider == .claude
                    ? (wave.up ? [(14, 1), (15, 1), (14, 2), (15, 2), (14, 3), (15, 3)]
                               : [(16, 1), (17, 1), (15, 2), (16, 2), (14, 3), (15, 3)])
                    : (wave.up ? [(15, 3), (16, 3), (15, 4), (16, 4), (15, 5)]
                               : [(17, 3), (18, 3), (16, 4), (17, 4), (15, 5)])
                for (c, r) in arm { pixel(Self.spriteX + c, Self.spriteY + r - hop, 1, 1, body) }
            }
            if unseen && !typing { PixelWorkbench.unseenDot(context, origin: origin, unit: unit, x: 19.5, y: 9.2) }
            if phase == .waiting {
                let qx: CGFloat = 32, qy: CGFloat = 6
                pixel(qx, qy, 2, 1, PixelWorkbench.amber)
                pixel(qx + 2, qy + 1, 1, 1, PixelWorkbench.amber)
                pixel(qx + 1, qy + 2, 1, 1, PixelWorkbench.amber)
                pixel(qx + 1, qy + 4, 1, 1, PixelWorkbench.amber)
            }
            if phase == .finished && hop > 0 {
                pixel(22, 9, 1, 1, tint.light)
                pixel(34, 8, 1, 1, tint.light)
                pixel(28, 7, 1, 1, tint.light)
            }
        }
    }
}
