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
        .frame(height: compact ? 76 : 96)
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
            .frame(height: compact ? 36 : 60)
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
    var date: Date
    var changedAt: Date
    var reduceMotion: Bool
    @Environment(\.colorScheme) private var colorScheme

    static let keystroke = 0.4   // unhurried: about 2.5 frames a second keeps the work scene light
    static let amber = Color(hex: 0xC89C4C)

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
            for (row, line) in rows.enumerated() {
                for (column, mark) in line.enumerated() where mark != "." {
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
