import SwiftUI

// MARK: - Palette & formatting

extension Color {
    init(hex: UInt32) {
        self.init(red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255, blue: Double(hex & 0xFF) / 255)
    }
}

enum WindowKind { case session, weekly }

/// How much of a window is used, in the six steps the colours follow.
/// The steps narrow towards the limit so the warning colours arrive early.
enum Level {
    case plenty, calm, fair, caution, warning, critical

    init(used: Int) {
        switch used {
        case ..<20: self = .plenty    // 水色  残り 81–100%
        case ..<40: self = .calm      // 緑    残り 61–80%
        case ..<60: self = .fair      // 紫    残り 41–60%
        case ..<75: self = .caution   // 黄    残り 26–40%
        case ..<90: self = .warning   // 橙    残り 11–25%
        default: self = .critical     // 赤    残り 0–10%
        }
    }
}

enum Palette {
    // Each ramp is [light, mid, deep]; rings sweep deep → light.
    static let green  = [Color(hex: 0x86E8B0), Color(hex: 0x34C77B), Color(hex: 0x1E9E5E)]
    static let sky    = [Color(hex: 0x9BE4FF), Color(hex: 0x3DB9F2), Color(hex: 0x1E8FD8)]
    static let purple = [Color(hex: 0xD6BCFF), Color(hex: 0xA873F5), Color(hex: 0x8350DE)]
    static let yellow = [Color(hex: 0xFFE38F), Color(hex: 0xF6C744), Color(hex: 0xDDA514)]
    static let orange = [Color(hex: 0xFFC08A), Color(hex: 0xFF9447), Color(hex: 0xEE7020)]
    static let red    = [Color(hex: 0xFF9A8F), Color(hex: 0xF0524F), Color(hex: 0xD2343A)]
    static let teal   = [Color(hex: 0x8EDBCB), Color(hex: 0x4DB6A4), Color(hex: 0x2E9583)]

    // Fixed per-service colours for the "固定" option.
    static let claude = [Color(hex: 0xF4A583), Color(hex: 0xD97757), Color(hex: 0xC0583A)]
    static let periwinkle = [Color(hex: 0xB3BEFF), Color(hex: 0x8193F6), Color(hex: 0x5D6EE3)]
    static let violet = [Color(hex: 0xCDBFFF), Color(hex: 0x9480F7), Color(hex: 0x6D5AE6)]

    static let claudeAccent = Color(hex: 0xD97757)
    static let codexAccent = Color(hex: 0x7C6CF2)

    static func ramp(provider: Provider, kind: WindowKind, used: Int, mode: ColorMode) -> [Color] {
        let level = Level(used: used)
        if mode == .brand {
            if level == .critical { return red }
            switch (provider, kind) {
            case (.claude, .session): return claude
            case (.claude, .weekly): return periwinkle
            case (.codex, .session): return violet
            case (.codex, .weekly): return sky
            }
        }
        if provider == .claude {
            return CharacterScale.ramp(CharacterScale.hex(forUsed: used, in: CharacterScale.current))
        }
        switch level {
        case .plenty: return sky
        case .calm: return green
        case .fair: return purple
        case .caution: return yellow
        case .warning: return orange
        case .critical: return red
        }
    }

    static func accent(_ p: Provider) -> Color { p == .claude ? claudeAccent : codexAccent }

    static func breakdown(_ key: String) -> Color {
        switch key {
        case "claude_code": return claude[1]
        case "chat": return periwinkle[1]
        case "cowork": return teal[1]
        default: return Color.gray.opacity(0.6)
        }
    }
}

enum ResetStyle { case long, short }

enum Fmt {
    static let jp = Locale(identifier: "ja_JP")

    static func format(_ d: Date, _ pattern: String) -> String {
        let f = DateFormatter()
        f.locale = jp
        f.dateFormat = pattern
        return f.string(from: d)
    }

    static func reset(_ d: Date?, now: Date, style: ResetStyle) -> String {
        guard let d else { return "未使用" }
        let s = d.timeIntervalSince(now)
        if s <= 0 { return "リセット済み" }
        let mins = Int((s / 60).rounded(.up))
        let body: String
        if mins < 60 {
            body = "\(mins)分後"
        } else if s < 24 * 3600 {
            let h = mins / 60, m = mins % 60
            body = m == 0 ? "\(h)時間後" : "\(h)時間\(m)分後"
        } else {
            // The API's timestamps jitter by a second or so around the hour; show the rounded minute.
            let rounded = Date(timeIntervalSinceReferenceDate: (d.timeIntervalSinceReferenceDate / 60).rounded() * 60)
            let t = format(rounded, "M/d(E) H:mm")
            return style == .long ? "\(t)にリセット" : t
        }
        return style == .long ? "\(body)にリセット" : body
    }

    /// "あと3時間53分" — the 5-hour window's countdown.
    static func countdown(_ w: UsageWindow?, now: Date) -> String {
        guard let d = w?.resetsAt else { return w == nil ? "未使用" : "使用前" }
        let s = d.timeIntervalSince(now)
        if s <= 0 { return "リセット済み" }
        let mins = Int((s / 60).rounded(.up))
        if mins < 60 { return "あと\(mins)分" }
        let h = mins / 60, m = mins % 60
        if h >= 24 { return "あと\(h / 24)日\(h % 24)時間" }
        return m == 0 ? "あと\(h)時間" : "あと\(h)時間\(m)分"
    }

    /// "9/28(月) 9:00" — the weekly window's reset, rounded to the minute.
    static func resetDate(_ w: UsageWindow?, now: Date) -> String {
        guard let d = w?.resetsAt else { return "未使用" }
        if d <= now { return "リセット済み" }
        return format(Date(timeIntervalSinceReferenceDate: (d.timeIntervalSinceReferenceDate / 60).rounded() * 60), "M/d(E) H:mm")
    }

    static func dollars(_ v: Double) -> String {
        v == v.rounded() ? "$\(Int(v))" : String(format: "$%.2f", v)
    }
}

// MARK: - State

struct Metric {
    let title: String
    let kind: WindowKind
    let window: UsageWindow?
    let provider: Provider
    let colorMode: ColorMode
    let now: Date

    /// A window whose reset time has passed is empty until the next fetch confirms it.
    var rolledOver: Bool { window?.resetsAt.map { $0 <= now } ?? false }
    var used: Int { rolledOver ? 0 : Int((window?.utilization ?? 0).rounded()) }
    func value(_ m: DisplayMode) -> Int { m == .used ? used : max(0, 100 - used) }
    func fraction(_ m: DisplayMode) -> Double { Double(value(m)) / 100 }
    var level: Level { Level(used: used) }
    var colors: [Color] { Palette.ramp(provider: provider, kind: kind, used: used, mode: colorMode) }
    func reset(_ style: ResetStyle) -> String {
        if window == nil { return "未使用" }
        return Fmt.reset(window?.resetsAt, now: now, style: style)
    }
    /// Text tint for the secondary figure: only call attention once it matters.
    var emphasis: AnyShapeStyle {
        level == .warning || level == .critical ? AnyShapeStyle(colors[1]) : AnyShapeStyle(.secondary)
    }
}

struct ProviderState: Identifiable {
    var provider: Provider
    var snapshot: UsageSnapshot?
    var error: String?
    var loading: Bool
    var stale: Bool
    var now: Date
    var mode: DisplayMode
    var colorMode: ColorMode
    var softError = false

    var id: Provider { provider }

    var fiveHour: Metric {
        Metric(title: "5時間制限", kind: .session, window: snapshot?.fiveHour, provider: provider, colorMode: colorMode, now: now)
    }
    var weekly: Metric {
        Metric(title: provider == .claude ? "週間・全モデル" : "週間制限", kind: .weekly, window: snapshot?.sevenDay,
               provider: provider, colorMode: colorMode, now: now)
    }
}

// MARK: - Building blocks

extension Color {
    /// Keeps a near-white step visible on light backgrounds (see `CharacterScale.legible`).
    func legible(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? self : Color(nsColor: CharacterScale.legible(NSColor(self), onDark: false))
    }
}

struct RingGauge: View {
    var progress: Double
    var lineWidth: CGFloat
    var colors: [Color]
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let p = min(max(progress, 0), 1)
        let colors = self.colors.map { $0.legible(scheme) }
        ZStack {
            Circle()
                .stroke(colors[1].opacity(0.16), lineWidth: lineWidth)
            if p > 0 {
                Circle()
                    .trim(from: 0, to: p)
                    .stroke(AngularGradient(colors: [colors[2], colors[1], colors[0]], center: .center,
                                            startAngle: .degrees(0), endAngle: .degrees(360 * p)),
                            style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .shadow(color: colors[1].opacity(0.45), radius: lineWidth * 0.35)
            }
        }
        .padding(lineWidth / 2)
        .animation(.spring(response: 0.9, dampingFraction: 0.85), value: p)
        .animation(.easeInOut(duration: 0.6), value: colors[1])
    }
}

/// The Claude spark, drawn as rays of slightly uneven length.
struct ClaudeSpark: View {
    var color: Color = Palette.claudeAccent

    var body: some View {
        Canvas { ctx, size in
            let c = CGPoint(x: size.width / 2, y: size.height / 2)
            let r = min(size.width, size.height) / 2
            let lengths: [CGFloat] = [1.0, 0.8, 0.94, 0.76, 1.0, 0.84, 0.92, 0.78, 0.98, 0.82, 0.9, 0.8]
            for (i, len) in lengths.enumerated() {
                let a = Double(i) / Double(lengths.count) * 2 * .pi - .pi / 2
                var path = Path()
                path.move(to: CGPoint(x: c.x + cos(a) * r * 0.16, y: c.y + sin(a) * r * 0.16))
                path.addLine(to: CGPoint(x: c.x + cos(a) * (r * len - r * 0.1), y: c.y + sin(a) * (r * len - r * 0.1)))
                ctx.stroke(path, with: .color(color), style: StrokeStyle(lineWidth: r * 0.2, lineCap: .round))
            }
        }
    }
}

/// A neutral terminal-prompt mark for Codex.
struct CodexGlyph: View {
    var body: some View {
        Canvas { ctx, size in
            let s = min(size.width, size.height)
            let rect = CGRect(x: (size.width - s) / 2, y: (size.height - s) / 2, width: s, height: s)
            ctx.fill(Path(roundedRect: rect, cornerRadius: s * 0.3, style: .continuous),
                     with: .linearGradient(Gradient(colors: [Color(hex: 0x9A8CFA), Color(hex: 0x4F7CF7)]),
                                           startPoint: CGPoint(x: rect.minX, y: rect.minY),
                                           endPoint: CGPoint(x: rect.maxX, y: rect.maxY)))
            let style = StrokeStyle(lineWidth: max(1, s * 0.11), lineCap: .round, lineJoin: .round)
            var chevron = Path()
            chevron.move(to: CGPoint(x: rect.minX + s * 0.26, y: rect.minY + s * 0.32))
            chevron.addLine(to: CGPoint(x: rect.minX + s * 0.45, y: rect.midY))
            chevron.addLine(to: CGPoint(x: rect.minX + s * 0.26, y: rect.maxY - s * 0.32))
            ctx.stroke(chevron, with: .color(.white), style: style)
            var underscore = Path()
            underscore.move(to: CGPoint(x: rect.minX + s * 0.54, y: rect.maxY - s * 0.31))
            underscore.addLine(to: CGPoint(x: rect.minX + s * 0.75, y: rect.maxY - s * 0.31))
            ctx.stroke(underscore, with: .color(.white), style: style)
        }
    }
}

struct ProviderLogo: View {
    var provider: Provider
    var body: some View {
        if provider == .claude { ClaudeSpark() } else { CodexGlyph() }
    }
}

struct PercentLabel: View {
    var value: Int
    var size: CGFloat

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 0.5) {
            Text("\(value)")
                .font(.system(size: size, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .contentTransition(.numericText(value: Double(value)))
            Text("%")
                .font(.system(size: size * 0.5, weight: .semibold, design: .rounded))
                .foregroundStyle(.secondary)
        }
    }
}

struct RingCaption: View {
    var mode: DisplayMode
    var size: CGFloat = 8.5
    var body: some View {
        Text(mode == .used ? "使用" : "残り")
            .font(.system(size: size, weight: .medium))
            .foregroundStyle(.secondary)
    }
}

struct PlanBadge: View {
    var plan: String
    var provider: Provider
    var body: some View {
        Text(plan)
            .font(.system(size: 9.5, weight: .bold, design: .rounded))
            .foregroundStyle(Palette.accent(provider))
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, 6)
            .padding(.vertical, 1.5)
            .background(Capsule().fill(Palette.accent(provider).opacity(0.16)))
    }
}

struct StatusBadge: View {
    var p: ProviderState
    var compact = false

    var body: some View {
        if p.loading {
            Spinner()
        } else if let e = p.error, p.softError {
            HStack(spacing: 3) {
                Image(systemName: "hourglass")
                if !compact { Text(e).lineLimit(1) }
            }
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(.secondary)
            .help(e)
        } else if let e = p.error {
            HStack(spacing: 3) {
                Image(systemName: "exclamationmark.triangle.fill")
                if !compact { Text(e).lineLimit(1) }
            }
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(.orange)
            .help(e)
        } else if let s = p.snapshot {
            Text(Fmt.format(s.fetchedAt, "H:mm"))
                .font(.system(size: 10.5, weight: .medium))
                .monospacedDigit()
                .foregroundStyle(p.stale ? AnyShapeStyle(.orange) : AnyShapeStyle(.tertiary))
        }
    }
}

struct Spinner: View {
    var size: CGFloat = 10
    @State private var spinning = false

    var body: some View {
        Circle()
            .trim(from: 0.12, to: 0.88)
            .stroke(.secondary, style: StrokeStyle(lineWidth: 1.6, lineCap: .round))
            .frame(width: size, height: size)
            .rotationEffect(.degrees(spinning ? 360 : 0))
            .animation(.linear(duration: 0.9).repeatForever(autoreverses: false), value: spinning)
            .onAppear { spinning = true }
    }
}

/// Lays a card out at its natural size, then draws everything — type, rings, spacing — `scale` times larger.
struct Magnify: Layout {
    var scale: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let child = subviews.first else { return .zero }
        let s = child.sizeThatFits(.unspecified)
        return CGSize(width: s.width * scale, height: s.height * scale)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard let child = subviews.first else { return }
        child.place(at: bounds.origin, anchor: .topLeading, proposal: ProposedViewSize(child.sizeThatFits(.unspecified)))
    }
}

extension View {
    func magnified(_ scale: CGFloat) -> some View {
        Magnify(scale: scale) { self.scaleEffect(scale, anchor: .topLeading) }
    }
}

struct HeaderRow: View {
    var p: ProviderState
    var compact = false

    var body: some View {
        HStack(spacing: 6) {
            ProviderLogo(provider: p.provider).frame(width: compact ? 12 : 14, height: compact ? 12 : 14)
            Text(p.provider.name).font(.system(size: compact ? 12 : 13, weight: .semibold))
            if !compact, let plan = p.snapshot?.plan { PlanBadge(plan: plan, provider: p.provider) }
            Spacer(minLength: 4)
            StatusBadge(p: p, compact: compact)
        }
    }
}

struct GaugeColumn: View {
    var metric: Metric
    var mode: DisplayMode
    var ring: CGFloat = 66

    var body: some View {
        HStack(spacing: 11) {
            ZStack {
                RingGauge(progress: metric.fraction(mode), lineWidth: 7.5, colors: metric.colors)
                VStack(spacing: -2) {
                    PercentLabel(value: metric.value(mode), size: 19)
                    RingCaption(mode: mode)
                }
            }
            .frame(width: ring, height: ring)

            VStack(alignment: .leading, spacing: 4) {
                Text(metric.title)
                    .font(.system(size: 12.5, weight: .semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                Text(mode == .used ? "残り \(metric.value(.remaining))%" : "使用 \(metric.used)%")
                    .font(.system(size: 11.5, weight: .medium))
                    .monospacedDigit()
                    .foregroundStyle(metric.emphasis)
            }
        }
    }
}

/// When each window resets, set large: a countdown for the 5-hour window, the date for the weekly one.
struct ResetTile: View {
    var metric: Metric

    var body: some View {
        let session = metric.kind == .session
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 4) {
                Image(systemName: session ? "timer" : "calendar")
                    .foregroundStyle(metric.colors[1])
                Text(session ? "5時間のリセットまで" : "週間のリセット")
                    .foregroundStyle(.secondary)
            }
            .font(.system(size: 10.5, weight: .semibold))
            Text(session ? Fmt.countdown(metric.window, now: metric.now) : Fmt.resetDate(metric.window, now: metric.now))
                .font(.system(size: 16, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 11, style: .continuous).fill(.primary.opacity(0.06)))
    }
}

struct ResetRow: View {
    var p: ProviderState
    var body: some View {
        HStack(spacing: 8) {
            ResetTile(metric: p.fiveHour)
            ResetTile(metric: p.weekly)
        }
    }
}

struct GaugePair: View {
    var p: ProviderState
    var body: some View {
        HStack(spacing: 8) {
            GaugeColumn(metric: p.fiveHour, mode: p.mode).frame(maxWidth: .infinity, alignment: .leading)
            GaugeColumn(metric: p.weekly, mode: p.mode).frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// Outer ring = 5-hour window, inner ring = weekly window.
struct ConcentricRings: View {
    var p: ProviderState
    var outer: CGFloat
    var inner: CGFloat
    var lineWidth: CGFloat
    var numberSize: CGFloat
    var caption: String?

    var body: some View {
        let f = p.fiveHour, w = p.weekly
        ZStack {
            RingGauge(progress: f.fraction(p.mode), lineWidth: lineWidth, colors: f.colors)
                .frame(width: outer, height: outer)
            RingGauge(progress: w.fraction(p.mode), lineWidth: lineWidth, colors: w.colors)
                .frame(width: inner, height: inner)
            VStack(spacing: -2) {
                PercentLabel(value: f.value(p.mode), size: numberSize)
                if let caption {
                    Text(caption).font(.system(size: max(7, numberSize * 0.44), weight: .medium)).foregroundStyle(.secondary)
                }
            }
        }
        .frame(width: outer, height: outer)
    }
}

struct Hairline: View {
    var body: some View { Rectangle().fill(.primary.opacity(0.08)).frame(height: 1) }
}

struct BarView: View {
    var fraction: Double
    var colors: [Color]
    var height: CGFloat = 6
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let colors = self.colors.map { $0.legible(scheme) }
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(colors[1].opacity(0.16))
                Capsule()
                    .fill(LinearGradient(colors: [colors[2], colors[0]], startPoint: .leading, endPoint: .trailing))
                    .frame(width: max(height, g.size.width * min(max(fraction, 0), 1)))
                    .opacity(fraction > 0 ? 1 : 0)
            }
        }
        .frame(height: height)
    }
}

struct Legend: View {
    var color: Color
    var text: String
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        HStack(spacing: 4) {
            Circle().fill(color.legible(scheme)).frame(width: 6, height: 6)
            Text(text).lineLimit(1)
        }
    }
}

// MARK: - Extras (large size)

struct BreakdownView: View {
    var rows: [BreakdownRow]

    var body: some View {
        let total = max(rows.reduce(0) { $0 + $1.percent }, 1)
        VStack(alignment: .leading, spacing: 7) {
            Text("今週の内訳").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
            GeometryReader { g in
                let gaps = CGFloat(rows.count - 1) * 2
                HStack(spacing: 2) {
                    ForEach(rows) { r in
                        Capsule()
                            .fill(Palette.breakdown(r.id))
                            .frame(width: max(4, (g.size.width - gaps) * r.percent / total))
                    }
                }
            }
            .frame(height: 6)
            HStack(spacing: 12) {
                ForEach(rows) { r in Legend(color: Palette.breakdown(r.id), text: "\(r.name) \(Int(r.percent))%") }
            }
            .font(.system(size: 10.5, weight: .medium))
            .foregroundStyle(.secondary)
        }
    }
}

struct CreditView: View {
    var credit: CreditInfo

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline) {
                Text("クラウドセッションクレジット").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                Spacer()
                Text("\(Fmt.dollars(credit.remaining)) / \(Fmt.dollars(credit.limit))")
                    .font(.system(size: 11, weight: .semibold))
                    .monospacedDigit()
            }
            BarView(fraction: credit.remaining / max(credit.limit, 0.01), colors: Palette.teal)
            if let e = credit.expiresAt {
                Text("\(Fmt.format(e, "M月d日 H:mm")) に期限切れ")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }
        }
    }
}

struct ProviderExtras: View {
    var p: ProviderState

    var body: some View {
        if let s = p.snapshot {
            if let e = s.loginExpiresAt, e.timeIntervalSince(p.now) < 3 * 86400 {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "key.fill").foregroundStyle(.orange)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Claude CLI のログイン期限: \(Fmt.format(e, "M/d H:mm"))")
                            .font(.system(size: 11, weight: .semibold))
                        Text("ターミナルで claude auth login を実行すると延長されます")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                    }
                }
            }
            if !s.extraWeekly.isEmpty {
                Hairline()
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(s.extraWeekly) { nw in
                        let m = Metric(title: nw.name, kind: .weekly, window: nw.window, provider: p.provider,
                                       colorMode: p.colorMode, now: p.now)
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text("週間・\(nw.name)").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                                Spacer()
                                Text("\(m.value(p.mode))%").font(.system(size: 11, weight: .semibold)).monospacedDigit()
                            }
                            BarView(fraction: m.fraction(p.mode), colors: m.colors)
                        }
                    }
                }
            }
            let rows = s.breakdown.filter { $0.percent > 0 }
            if !rows.isEmpty {
                Hairline()
                BreakdownView(rows: rows)
            }
            if let c = s.credit {
                Hairline()
                CreditView(credit: c)
            }
            if let n = s.resetCredits, n > 0 {
                Hairline()
                HStack(spacing: 6) {
                    Image(systemName: "arrow.counterclockwise.circle.fill").foregroundStyle(Palette.codexAccent)
                    Text("無料リセット").foregroundStyle(.secondary)
                    Spacer()
                    Text("あと \(n) 回使えます").monospacedDigit()
                }
                .font(.system(size: 11, weight: .semibold))
            }
        }
    }
}

// MARK: - Single-service cards

struct SmallCard: View {
    var p: ProviderState

    var body: some View {
        let f = p.fiveHour, w = p.weekly
        VStack(spacing: 0) {
            HeaderRow(p: p, compact: true)
            Spacer(minLength: 0)
            ConcentricRings(p: p, outer: 100, inner: 74, lineWidth: 10, numberSize: 18,
                            caption: p.mode == .used ? "5時間" : "5時間 残り")
            Spacer(minLength: 0)
            HStack(spacing: 0) {
                Legend(color: w.colors[1], text: "週 \(w.value(p.mode))%")
                Spacer(minLength: 4)
                HStack(spacing: 3) {
                    Image(systemName: "clock").font(.system(size: 8, weight: .semibold))
                    Text(f.reset(.short))
                }
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            }
            .font(.system(size: 10, weight: .medium))
            .monospacedDigit()
            .foregroundStyle(.secondary)
        }
        .padding(14)
        .frame(width: 164, height: 164)
    }
}

struct MediumCard: View {
    var p: ProviderState

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HeaderRow(p: p)
            GaugePair(p: p)
            ResetRow(p: p)
        }
        .padding(16)
        .frame(width: 344)
        .fixedSize(horizontal: false, vertical: true)
    }
}

struct ProviderSection: View {
    var p: ProviderState
    var extras = true
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HeaderRow(p: p)
            GaugePair(p: p)
            ResetRow(p: p)
            if extras { ProviderExtras(p: p) }
        }
    }
}

struct LargeCard: View {
    var items: [ProviderState]
    var width: CGFloat = 344
    var padding: CGFloat = 16
    var extras = true

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            ForEach(Array(items.enumerated()), id: \.element.id) { i, p in
                if i > 0 {
                    Rectangle().fill(.primary.opacity(0.14)).frame(height: 1)
                }
                ProviderSection(p: p, extras: extras)
            }
        }
        .padding(padding)
        .frame(width: width)
        .fixedSize(horizontal: false, vertical: true)
    }
}

// MARK: - Two-service cards

struct DualSmallCard: View {
    var items: [ProviderState]

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            ForEach(items) { p in
                VStack(spacing: 6) {
                    ConcentricRings(p: p, outer: 62, inner: 44, lineWidth: 7, numberSize: 12.5, caption: nil)
                        .overlay(alignment: .topTrailing) {
                            if p.error != nil {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .font(.system(size: 9)).foregroundStyle(.orange).offset(x: 4, y: -2)
                            }
                        }
                    HStack(spacing: 4) {
                        ProviderLogo(provider: p.provider).frame(width: 11, height: 11)
                        Text(p.provider.name).font(.system(size: 11, weight: .semibold))
                    }
                    VStack(spacing: 2) {
                        Text("週 \(p.weekly.value(p.mode))%")
                            .foregroundStyle(p.weekly.emphasis)
                        Text(p.fiveHour.reset(.short))
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                    }
                    .font(.system(size: 9.5, weight: .medium))
                    .monospacedDigit()
                }
                .frame(maxWidth: .infinity)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 14)
        .frame(width: 164, height: 164)
    }
}

struct DualMediumCard: View {
    var items: [ProviderState]

    var body: some View {
        HStack(spacing: 13) {
            ForEach(Array(items.enumerated()), id: \.element.id) { i, p in
                if i > 0 { Rectangle().fill(.primary.opacity(0.08)).frame(width: 1) }
                HalfPanel(p: p)
            }
        }
        .padding(16)
        .frame(width: 344)
        .fixedSize(horizontal: false, vertical: true)
    }
}

struct HalfPanel: View {
    var p: ProviderState

    var body: some View {
        let f = p.fiveHour, w = p.weekly
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 5) {
                ProviderLogo(provider: p.provider).frame(width: 13, height: 13)
                Text(p.provider.name).font(.system(size: 12.5, weight: .semibold))
                if let plan = p.snapshot?.plan { PlanBadge(plan: plan, provider: p.provider) }
                Spacer(minLength: 2)
                StatusBadge(p: p, compact: true)
            }
            HStack(spacing: 10) {
                ConcentricRings(p: p, outer: 60, inner: 43, lineWidth: 6.5, numberSize: 12,
                                caption: p.mode == .used ? "使用" : "残り")
                VStack(alignment: .leading, spacing: 6) {
                    Legend(color: f.colors[1], text: "5時間 \(f.value(p.mode))%")
                    Legend(color: w.colors[1], text: "週間 \(w.value(p.mode))%")
                }
                .font(.system(size: 11.5, weight: .medium))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            }
            VStack(alignment: .leading, spacing: 4) {
                ResetLine(icon: "timer", color: f.colors[1], text: Fmt.countdown(f.window, now: p.now))
                ResetLine(icon: "calendar", color: w.colors[1], text: Fmt.resetDate(w.window, now: p.now))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct ResetLine: View {
    var icon: String
    var color: Color
    var text: String
    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: icon).font(.system(size: 10.5, weight: .semibold)).foregroundStyle(color)
            Text(text)
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.75)
        }
    }
}

// MARK: - Live roots

extension UsageStore {
    func states(_ settings: Settings, providers: [Provider]? = nil) -> [ProviderState] {
        (providers ?? settings.providerSelection.providers).map { p in
            let st = self[p]
            return ProviderState(provider: p, snapshot: st.snapshot, error: st.error, loading: st.loading,
                                 stale: isStale(p), now: now, mode: settings.displayMode, colorMode: settings.colorMode,
                                 softError: st.softError)
        }
    }
}

struct WidgetRoot: View {
    @ObservedObject var store: UsageStore
    @ObservedObject var settings: Settings
    @ObservedObject var activity = WorkActivityStore.shared
    @ObservedObject var hover = WidgetHover.shared

    var body: some View {
        let contents = WidgetContents(items: store.states(settings), size: settings.widgetSize,
                                      workStates: settings.showWorkScene ? activity.states : nil,
                                      characterColor: settings.characterColor, showDetails: settings.showWidgetDetails,
                                      sceneStyle: settings.workSceneStyle)
        Group {
            if abs(settings.widgetZoom - 1) < 0.001 { contents } else { contents.magnified(settings.widgetZoom) }
        }
        // A grip in the corner, shown on hover, says the widget can be resized by dragging.
        .overlay(alignment: .bottomTrailing) {
            ResizeGrip()
                .frame(width: 11, height: 11)
                .padding(9 * max(1, settings.widgetZoom * 0.9))
                .opacity(hover.hovering || hover.resizing ? 1 : 0)
                .animation(.easeOut(duration: 0.15), value: hover.hovering)
        }
    }
}

struct ResizeGrip: View {
    var body: some View {
        Canvas { ctx, size in
            for k in 1...3 {
                let d = CGFloat(k) * size.width / 3
                var p = Path()
                p.move(to: CGPoint(x: size.width - d, y: size.height))
                p.addLine(to: CGPoint(x: size.width, y: size.height - d))
                ctx.stroke(p, with: .color(.secondary), style: StrokeStyle(lineWidth: 1.3, lineCap: .round))
            }
        }
    }
}

/// The same layout is used for the live widget and deterministic offline previews.
struct WidgetContents: View {
    var items: [ProviderState]
    var size: WidgetSize
    var workStates: [Provider: WorkActivity]?
    var characterColor: CharacterColor = .level
    var showDetails = false
    var sceneStyle: WorkSceneStyle = .desk
    var previewDate: Date? = nil

    private var tints: [Provider: CharacterTint] {
        Dictionary(uniqueKeysWithValues: items.map { ($0.provider, CharacterTint.for($0, option: characterColor)) })
    }

    private var width: CGFloat { size == .small ? 164 : (size == .large ? 344 * WidgetSize.largeScale : 344) }

    var body: some View {
        VStack(spacing: 0) {
            usageCard
            if let workStates {
                if size == .large {
                    WorkSceneFooter(providers: items.map(\.provider), states: workStates, tints: tints,
                                    style: sceneStyle, previewDate: previewDate)
                        .frame(width: 344).magnified(WidgetSize.largeScale)
                } else {
                    WorkSceneFooter(providers: items.map(\.provider), states: workStates, tints: tints,
                                    style: sceneStyle, compact: size == .small, previewDate: previewDate)
                }
            }
        }
        .frame(width: width)
        .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder private var usageCard: some View {
        if size == .large {
            // Same content as the menu card, drawn larger so the extra room goes to legibility.
            LargeCard(items: items, extras: showDetails).magnified(WidgetSize.largeScale)
        } else if items.count == 1 {
            if size == .small { SmallCard(p: items[0]) } else { MediumCard(p: items[0]) }
        } else {
            if size == .small { DualSmallCard(items: items) } else { DualMediumCard(items: items) }
        }
    }
}
