import SwiftUI

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

    /// Claude follows its 5-hour level, exactly like the menu bar character; Codex keeps its own colour.
    static func `for`(_ p: ProviderState, option: CharacterColor) -> CharacterTint {
        guard p.provider == .claude else { return .codex }
        guard p.snapshot != nil else { return CharacterTint(Palette.claude) }
        let used = p.fiveHour.used
        if option == .claude { return CharacterTint(Level(used: used) == .critical ? Palette.red : Palette.claude) }
        return CharacterTint(Palette.ramp(provider: .claude, kind: .session, used: used, mode: .level))
    }
}

/// A quiet workbench under the usage gauges. The monitor alone selects the work phase.
struct WorkSceneFooter: View {
    var providers: [Provider]
    var states: [Provider: WorkActivity]
    var tints: [Provider: CharacterTint] = [:]
    var compact = false
    /// A fixed clock for image/GIF previews; never used to manufacture live activity.
    var previewDate: Date? = nil

    var body: some View {
        VStack(spacing: 0) {
            Rectangle().fill(.primary.opacity(0.08)).frame(height: 1)
            HStack(alignment: .top, spacing: compact ? 2 : 12) {
                ForEach(providers) { provider in
                    WorkSceneTile(provider: provider,
                                  activity: states[provider] ?? WorkActivity(phase: .unknown, sessionCount: 0,
                                                                           detail: "作業状態をまだ検出していません", changedAt: .distantPast),
                                  tint: tints[provider] ?? (provider == .claude ? CharacterTint(Palette.claude) : .codex),
                                  compact: compact, previewDate: previewDate)
                    .frame(maxWidth: .infinity)
                }
            }
            .padding(.horizontal, compact ? 8 : 14)
            .padding(.top, 5)
            .padding(.bottom, 9)
        }
        .frame(height: compact ? 84 : 104)
    }
}

private struct WorkSceneTile: View {
    var provider: Provider
    var activity: WorkActivity
    var tint: CharacterTint
    var compact: Bool
    var previewDate: Date?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ObservedObject private var visibility = SceneVisibility.shared

    private var label: String {
        switch activity.phase {
        case .working: return "作業中"
        case .waiting: return "確認待ち"
        case .finished: return "完了"
        case .idle: return "待機中"
        case .unknown: return "未検出"
        }
    }

    private var indicator: Color {
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
                                              blinkOffset: provider == .claude ? 0 : 3)) { clock in
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
        .accessibilityLabel("\(provider.name)、\(label)\(activity.sessionCount > 1 ? "、\(activity.sessionCount)セッション" : "")")
        .help(activity.detail)
    }

    private func scene(at date: Date) -> some View {
        PixelWorkbench(provider: provider, phase: activity.phase, tint: tint, date: date,
                       changedAt: activity.changedAt, reduceMotion: reduceMotion)
            .frame(height: compact ? 42 : 66)
            .accessibilityHidden(true)
    }
}

/// Continuous redraws are limited to real work. Resting characters wake twice every seven
/// seconds to blink; the celebration produces one finite burst and then stops scheduling.
private struct WorkSceneSchedule: TimelineSchedule {
    var phase: WorkPhase
    var changedAt: Date
    var reducedMotion: Bool
    var blinkOffset: Double

    func entries(from startDate: Date, mode: Mode) -> AnySequence<Date> {
        guard !reducedMotion, phase != .unknown else { return AnySequence([startDate]) }
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
            // A steady, unhurried beat: the hand taps and the screen breathes.
            let step = mode == .lowFrequency ? PixelWorkbench.keystroke * 2 : PixelWorkbench.keystroke
            return AnySequence {
                var next = startDate
                return AnyIterator<Date> {
                    defer { next = next.addingTimeInterval(step) }
                    return next
                }
            }
        }
        if phase == .waiting {
            // The question mark only needs a slow bob.
            let step = 0.5
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

/// Pixel-native desk scene on a fixed 36 × 26 grid (y grows downwards).
/// While working the character sits side-on to a laptop on a low desk and taps away calmly
/// while the screen glows; finishing is marked by a hop.
/// Claude keeps its familiar silhouette; Codex gets an original terminal-shaped companion.
struct PixelWorkbench: View {
    var provider: Provider
    var phase: WorkPhase
    var tint: CharacterTint
    var date: Date
    var changedAt: Date
    var reduceMotion: Bool
    @Environment(\.colorScheme) private var colorScheme

    static let keystroke = 0.32
    static let amber = Color(hex: 0xE8A93A)

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

    // Where things sit on the grid.
    private static let spriteX: CGFloat = 18, spriteY: CGFloat = 15
    private static let deskY: CGFloat = 22, keyboardY: CGFloat = 21

    var body: some View {
        Canvas { context, size in
            let unit = max(0.5, (min(size.width / 36, size.height / 26) * 2).rounded(.down) / 2)
            let origin = CGPoint(x: ((size.width - 36 * unit) / 2 * 2).rounded() / 2, y: size.height - 26 * unit)
            let dark = colorScheme == .dark
            let time = date.timeIntervalSinceReferenceDate
            let beat = reduceMotion ? 0 : Int(floor(time / Self.keystroke))
            let elapsed = date.timeIntervalSince(changedAt)

            func pixel(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat = 1, _ h: CGFloat = 1, _ color: Color) {
                let rect = CGRect(x: origin.x + x * unit, y: origin.y + y * unit, width: w * unit, height: h * unit)
                context.fill(Path(rect), with: .color(color), style: FillStyle(antialiased: false))
            }

            // Colours
            let unknown = phase == .unknown
            let body = unknown ? Color.secondary.opacity(0.45) : tint.body
            let shade = unknown ? Color.secondary.opacity(0.35) : tint.shade
            let eye = Color(hex: 0x25201E)
            let wood = dark ? Color(hex: 0x6B5A4B) : Color(hex: 0xB89878)
            let woodEdge = dark ? Color(hex: 0x54463A) : Color(hex: 0x9C7C5E)
            let laptop = dark ? Color(hex: 0x9AA1AD) : Color(hex: 0x7D8491)
            let laptopEdge = dark ? Color(hex: 0x767D89) : Color(hex: 0x626874)

            // Where the character is looking: side-on while typing, with a glance every few seconds.
            // While working the character faces the laptop and taps away calmly; finishing is
            // marked by the hop, so the working state itself stays quiet.
            let typing = phase == .working
            let sideOn = typing
            let pressing = typing && !reduceMotion
            let glow = reduceMotion ? 1.0 : 0.75 + 0.25 * sin(time * 2 * .pi / 1.6)

            // Floor and low desk. The furniture never moves, so animation cannot shift the card.
            pixel(0, 25, 36, 0.5, .primary.opacity(0.10))
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
                case .waiting: screen = Self.amber.opacity(reduceMotion || Int(time * 2) % 2 == 0 ? 1 : 0.45)
                default: screen = Color(hex: 0x5BD38A)
                }
                // The lid leans back from the hinge; its lit face turns towards the character.
                for i in 0..<8 {
                    let x = 7 - CGFloat((i * 3) / 8), y = Self.keyboardY - 1 - CGFloat(i)
                    pixel(x - 1, y, 1, 1, laptopEdge)
                    pixel(x, y, 1, 1, screen)
                    // The lit screen spills a little light towards the keyboard.
                    if typing { pixel(x + 1, y, 1, 1, tint.light.opacity(0.22 * glow)) }
                }
                // Keys lighting up under the typing hand.
                if pressing && beat % 2 == 0 {
                    pixel(9 + CGFloat((beat / 2 * 5) % 9), Self.keyboardY, 1, 0.5, tint.light)
                }
            } else {
                pixel(7, Self.keyboardY - 0.5, 13, 0.5, laptopEdge)
            }

            // Character
            let hop = !reduceMotion && phase == .finished && elapsed >= 0 && elapsed < 0.9
                ? CGFloat((sin(elapsed / 0.9 * .pi) * 3).rounded()) : 0
            let tapDown = pressing && beat % 2 == 0
            let bob: CGFloat = tapDown ? 0.5 : 0
            let blinkTime = (time + (provider == .claude ? 0 : 3)).truncatingRemainder(dividingBy: 7)
            let blinking = !reduceMotion && !unknown && !sideOn && blinkTime >= 0 && blinkTime < 0.14
            let rows = provider == .claude ? (sideOn ? Self.claudeSide : Self.claudeFront)
                                           : (sideOn ? Self.codexSide : Self.codexFront)
            for (r, line) in rows.enumerated() {
                for (c, mark) in line.enumerated() where mark != "." {
                    let x = Self.spriteX + CGFloat(c)
                    var y = Self.spriteY + CGFloat(r) - hop + bob
                    switch mark {
                    case "S": pixel(x, y, 1, 1, shade)
                    case "A":
                        if tapDown { y += 1 }      // the hand comes down onto the keys
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
                // A >_ expression identifies the terminal companion without borrowing a mascot.
                let face = Color.white.opacity(unknown ? 0.5 : 0.9)
                let fx = Self.spriteX + (sideOn ? 3 : 4), fy = Self.spriteY - hop + bob
                pixel(fx, fy + 2, 1, 1, face)
                pixel(fx + 1, fy + 3, 1, 1, face)
                pixel(fx, fy + 4, 1, 1, face)
                if !blinking { pixel(fx + (sideOn ? 3 : 5), fy + 4.5, sideOn ? 2 : 3, 0.5, face) }
            }

            // A question mark bobbing over the head while waiting for you.
            if phase == .waiting {
                let lift: CGFloat = reduceMotion || Int(time * 2) % 2 == 0 ? 0 : 1
                let qx: CGFloat = 32, qy: CGFloat = 8 - lift
                pixel(qx, qy, 2, 1, Self.amber)
                pixel(qx + 2, qy + 1, 1, 1, Self.amber)
                pixel(qx + 1, qy + 2, 1, 1, Self.amber)
                pixel(qx + 1, qy + 4, 1, 1, Self.amber)
            }
            if phase == .finished && hop > 0 {
                pixel(22, 11, 1, 1, tint.light)
                pixel(34, 10, 1, 1, tint.light)
                pixel(28, 9, 1, 1, tint.light)
            }
        }
    }
}
