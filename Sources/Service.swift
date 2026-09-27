import AppKit
import Foundation

// MARK: - Subprocess

enum Shell {
    struct Output { var status: Int32; var stdout: Data }

    private final class Box: @unchecked Sendable { var data = Data() }

    static let path = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"

    static func environment() -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = path
        return env
    }

    static func findExecutable(_ name: String) -> String? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let dirs = ["/opt/homebrew/bin", "/usr/local/bin", "\(home)/.local/bin", "\(home)/.npm-global/bin",
                    "\(home)/.claude/local", "\(home)/.bun/bin"]
        return dirs.map { "\($0)/\(name)" }.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    static func run(_ path: String, _ args: [String], timeout: TimeInterval, cwd: URL? = nil) throws -> Output {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        if let cwd { p.currentDirectoryURL = cwd }
        p.environment = environment()
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        p.standardInput = FileHandle.nullDevice
        try p.run()

        // Drain stdout concurrently so a full pipe can't stall the child.
        let box = Box()
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global().async {
            box.data = out.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }
        if group.wait(timeout: .now() + timeout) == .timedOut {
            p.terminate()
            _ = group.wait(timeout: .now() + 2)
        }
        p.waitUntilExit()
        return Output(status: p.terminationStatus, stdout: box.data)
    }
}

// MARK: - Claude credentials (read-only)

struct OAuthCredential {
    var accessToken: String
    var expiresAt: Date?
    var subscriptionType: String?
    var rateLimitTier: String?
    var loginExpiresAt: Date?

    var isExpired: Bool {
        guard let expiresAt else { return false }
        return expiresAt.timeIntervalSinceNow < 60
    }

    var planName: String? {
        guard let s = subscriptionType?.lowercased() else { return nil }
        let tier = rateLimitTier ?? ""
        switch s {
        case "pro": return "Pro"
        case "max": return tier.contains("20x") ? "Max 20x" : tier.contains("5x") ? "Max 5x" : "Max"
        case "team": return "Team"
        case "enterprise": return "Enterprise"
        default: return s.capitalized
        }
    }
}

/// Reads the token Claude Code keeps in the login keychain. Never writes to it:
/// when the token is stale, the claude CLI is asked to refresh it itself.
enum CredentialStore {
    static let service = "Claude Code-credentials"

    static func load() throws -> OAuthCredential {
        var data: Data?
        if let r = try? Shell.run("/usr/bin/security", ["find-generic-password", "-s", service, "-w"], timeout: 10),
           r.status == 0, !r.stdout.isEmpty {
            data = r.stdout
        } else {
            let file = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/.credentials.json")
            data = try? Data(contentsOf: file)
        }
        guard let data,
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let o = root["claudeAiOauth"] as? [String: Any],
              let token = o["accessToken"] as? String, !token.isEmpty
        else { throw GaugeError.noCredentials }

        let expires = (o["expiresAt"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue / 1000) }
        return OAuthCredential(accessToken: token, expiresAt: expires,
                               subscriptionType: o["subscriptionType"] as? String,
                               rateLimitTier: o["rateLimitTier"] as? String,
                               loginExpiresAt: (o["refreshTokenExpiresAt"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue / 1000) })
    }
}

/// Lets the official CLI renew its own token by making the smallest possible request
/// (Haiku, no tools, no settings, a one-word reply — a few hundred tokens).
enum CLIRefresher {
    static func refresh() throws {
        guard let claude = Shell.findExecutable("claude") else { throw GaugeError.cliMissing }
        let args = ["-p", "ok", "--model", "haiku",
                    "--system-prompt", "Reply with the single word: ok",
                    "--tools", "", "--setting-sources", "", "--strict-mcp-config",
                    "--no-session-persistence", "--disable-slash-commands",
                    "--output-format", "json"]
        let r = try Shell.run(claude, args, timeout: 90, cwd: FileManager.default.temporaryDirectory)
        if r.status != 0 { throw GaugeError.cliFailed }
    }
}

enum ClaudeAPI {
    static let endpoint = URL(string: "https://api.anthropic.com/api/oauth/usage")!

    static func fetch(token: String) async throws -> Data {
        var req = URLRequest(url: endpoint, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue("ClaudeCodexUsage/1.1", forHTTPHeaderField: "User-Agent")

        let data: Data, resp: URLResponse
        do { (data, resp) = try await URLSession.shared.data(for: req) } catch { throw GaugeError.network }
        switch (resp as? HTTPURLResponse)?.statusCode ?? 0 {
        case 200: return data
        case 401, 403: throw GaugeError.unauthorized
        case 429:
            let after = (resp as? HTTPURLResponse)?.value(forHTTPHeaderField: "Retry-After").flatMap(Double.init)
            throw GaugeError.rateLimited(after)
        case let code: throw GaugeError.http(code)
        }
    }

    nonisolated static func load(allowCLI: Bool) async -> (Result<UsageSnapshot, Error>, Bool) {
        var ranCLI = false
        func renew() async throws -> OAuthCredential {
            ranCLI = true
            try await Task.detached { try CLIRefresher.refresh() }.value
            return try await Task.detached { try CredentialStore.load() }.value
        }
        do {
            var cred = try await Task.detached { try CredentialStore.load() }.value
            if cred.isExpired {
                guard allowCLI else { throw GaugeError.tokenExpired }
                cred = try await renew()
                if cred.isExpired { throw GaugeError.tokenExpired }
            }
            let data: Data
            do {
                data = try await fetch(token: cred.accessToken)
            } catch GaugeError.unauthorized where allowCLI && !ranCLI {
                cred = try await renew()
                data = try await fetch(token: cred.accessToken)
            }
            var snap = try UsageParser.parse(data, plan: cred.planName)
            snap.loginExpiresAt = cred.loginExpiresAt
            return (.success(snap), ranCLI)
        } catch {
            return (.failure(error), ranCLI)
        }
    }
}

// MARK: - Codex (official `codex app-server` JSON-RPC; the CLI handles its own auth)

enum CodexRPC {
    /// Collects newline-delimited JSON messages from the child's stdout.
    private final class LineBuffer: @unchecked Sendable {
        private let lock = NSLock()
        private var pending = Data()
        private var lines: [Data] = []
        private var closed = false
        private let signal = DispatchSemaphore(value: 0)

        func append(_ d: Data) {
            lock.lock()
            if d.isEmpty {
                closed = true
            } else {
                pending.append(d)
                while let nl = pending.firstIndex(of: 0x0A) {
                    lines.append(Data(pending[pending.startIndex..<nl]))
                    pending = Data(pending[(nl + 1)...])
                }
            }
            lock.unlock()
            signal.signal()
        }

        func next(until deadline: Date) -> Data? {
            while true {
                lock.lock()
                if !lines.isEmpty {
                    let line = lines.removeFirst()
                    lock.unlock()
                    return line
                }
                let isClosed = closed
                lock.unlock()
                let remaining = deadline.timeIntervalSinceNow
                if isClosed || remaining <= 0 { return nil }
                _ = signal.wait(timeout: .now() + remaining)
            }
        }
    }

    static func readRateLimits(timeout: TimeInterval = 25) throws -> [String: Any] {
        guard let codex = Shell.findExecutable("codex") else { throw GaugeError.codexMissing }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: codex)
        p.arguments = ["-s", "read-only", "-a", "never", "app-server"]
        p.currentDirectoryURL = FileManager.default.temporaryDirectory
        p.environment = Shell.environment()
        let input = Pipe(), output = Pipe()
        p.standardInput = input
        p.standardOutput = output
        p.standardError = FileHandle.nullDevice

        let buffer = LineBuffer()
        output.fileHandleForReading.readabilityHandler = { h in
            let d = h.availableData
            if d.isEmpty { h.readabilityHandler = nil }
            buffer.append(d)
        }
        try p.run()
        defer {
            output.fileHandleForReading.readabilityHandler = nil
            try? input.fileHandleForWriting.close()
            if p.isRunning { p.terminate() }
        }

        let deadline = Date().addingTimeInterval(timeout)
        func send(_ message: [String: Any]) throws {
            var data = try JSONSerialization.data(withJSONObject: message)
            data.append(0x0A)
            do { try input.fileHandleForWriting.write(contentsOf: data) } catch { throw GaugeError.codexFailed }
        }
        func response(to id: Int) throws -> [String: Any] {
            while let line = buffer.next(until: deadline) {
                guard let msg = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                      (msg["id"] as? NSNumber)?.intValue == id else { continue }
                if let err = msg["error"] as? [String: Any] {
                    let text = ((err["message"] as? String) ?? "").lowercased()
                    let auth = ["auth", "login", "logged", "credential", "token"].contains { text.contains($0) }
                    throw auth ? GaugeError.codexNotLoggedIn : GaugeError.codexFailed
                }
                return (msg["result"] as? [String: Any]) ?? [:]
            }
            throw GaugeError.codexFailed
        }

        try send(["method": "initialize", "id": 0,
                  "params": ["clientInfo": ["name": "claude_codex_usage", "title": "Claude & Codex Usage", "version": "1.1"]]])
        _ = try response(to: 0)
        try send(["method": "initialized"])
        try send(["method": "account/rateLimits/read", "id": 1])
        return try response(to: 1)
    }

    nonisolated static func load() async -> Result<UsageSnapshot, Error> {
        do {
            let result = try await Task.detached { try readRateLimits() }.value
            return .success(try CodexParser.parse(result))
        } catch {
            return .failure(error)
        }
    }
}

// MARK: - Store

struct ProviderStatus: Equatable {
    var snapshot: UsageSnapshot?
    var error: String?
    var loading = false
    /// A temporary condition (e.g. the server asked us to slow down); the numbers shown are still good.
    var softError = false
}

@MainActor
final class UsageStore: ObservableObject {
    static let shared = UsageStore()

    @Published private(set) var status: [Provider: ProviderStatus] = [:]
    @Published private(set) var now = Date()

    private var pollTimer: Timer?
    private var clockTimer: Timer?
    private var scheduledInterval = 0
    private var lastAttempt: [Provider: Date] = [:]
    private var rateLimitedUntil: [Provider: Date] = [:]
    private var lastCLIRefresh: Date?

    private static func cacheKey(_ p: Provider) -> String { p == .claude ? "lastSnapshot" : "lastSnapshot.\(p.rawValue)" }

    init() {
        for p in Provider.allCases {
            if let d = UserDefaults.standard.data(forKey: Self.cacheKey(p)),
               let s = try? JSONDecoder().decode(UsageSnapshot.self, from: d) {
                status[p] = ProviderStatus(snapshot: s)
            }
        }
    }

    subscript(_ p: Provider) -> ProviderStatus { status[p] ?? ProviderStatus() }

    func start() {
        refresh()
        reschedule()
        clockTimer = Timer.scheduledTimer(withTimeInterval: 20, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification,
                                                          object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(6))   // give Wi-Fi a moment
                self?.refresh()
            }
        }
    }

    func reschedule() {
        let minutes = Settings.shared.intervalMinutes
        guard minutes != scheduledInterval else { return }
        scheduledInterval = minutes
        pollTimer?.invalidate()
        pollTimer = Timer.scheduledTimer(withTimeInterval: TimeInterval(minutes * 60), repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        pollTimer?.tolerance = 20
    }

    func isStale(_ p: Provider) -> Bool {
        guard let s = self[p].snapshot else { return false }
        return now.timeIntervalSince(s.fetchedAt) > max(Double(Settings.shared.intervalMinutes * 60) * 3, 20 * 60)
    }

    /// Fetches services that have never been fetched (e.g. one that was just switched on).
    func refreshMissing() {
        for p in Settings.shared.activeProviders where self[p].snapshot == nil { refresh(p) }
    }

    func refreshIfStale(_ age: TimeInterval = 300) {
        for p in Settings.shared.activeProviders {
            if let s = self[p].snapshot, Date().timeIntervalSince(s.fetchedAt) < age { continue }
            refresh(p)
        }
    }

    func refresh(manual: Bool = false) {
        for p in Settings.shared.activeProviders { refresh(p, manual: manual) }
    }

    /// `--offline`: show the cached numbers without contacting any service (used for screenshots).
    static var offline = false

    private func refresh(_ p: Provider, manual: Bool = false) {
        guard !Self.offline else { return }
        guard !self[p].loading else { return }
        // Even a manual refresh waits out a "slow down" from the server; retrying early only extends it.
        if let until = rateLimitedUntil[p], until > Date() { return }
        if let last = lastAttempt[p], Date().timeIntervalSince(last) < (manual ? 20 : 45) { return }
        lastAttempt[p] = Date()
        status[p, default: ProviderStatus()].loading = true

        Task {
            let result: Result<UsageSnapshot, Error>
            switch p {
            case .claude:
                let canRunCLI = manual || (lastCLIRefresh.map { Date().timeIntervalSince($0) > 15 * 60 } ?? true)
                let allowCLI = (Settings.shared.autoCLIRefresh || manual) && canRunCLI
                let (r, ranCLI) = await ClaudeAPI.load(allowCLI: allowCLI)
                if ranCLI { lastCLIRefresh = Date() }
                result = r
            case .codex:
                result = await CodexRPC.load()
            }

            var st = self[p]
            st.loading = false
            switch result {
            case .success(let s):
                st.snapshot = s
                st.error = nil
                st.softError = false
                rateLimitedUntil[p] = nil
                if let d = try? JSONEncoder().encode(s) { UserDefaults.standard.set(d, forKey: Self.cacheKey(p)) }
            case .failure(let e):
                if case GaugeError.rateLimited(let after) = e {
                    let wait = min(max(after ?? 600, 60), 1800)
                    let until = Date().addingTimeInterval(wait)
                    rateLimitedUntil[p] = until
                    st.error = "混雑中・\(Fmt.format(until, "H:mm")) に自動で再取得"
                    st.softError = true
                    Timer.scheduledTimer(withTimeInterval: wait + 5, repeats: false) { [weak self] _ in
                        Task { @MainActor in self?.refresh(p) }
                    }
                } else {
                    st.error = (e as? LocalizedError)?.errorDescription ?? e.localizedDescription
                    st.softError = false
                }
            }
            status[p] = st
            now = Date()
        }
    }

    private func tick() {
        now = Date()
        // A window just rolled over since the last fetch — pick up the fresh numbers.
        for p in Settings.shared.activeProviders {
            guard let s = self[p].snapshot else { continue }
            let resets = [s.fiveHour?.resetsAt, s.sevenDay?.resetsAt].compactMap { $0 }
            if resets.contains(where: { $0 > s.fetchedAt && now.timeIntervalSince($0) > 20 }) { refresh(p) }
        }
    }
}

// MARK: - Settings

enum WidgetSize: String, CaseIterable { case small, medium, large
    var label: String { ["small": "小", "medium": "中", "large": "大（文字も大きく）"][rawValue]! }
    static let largeScale: CGFloat = 1.25
}
enum Placement: String, CaseIterable { case desktop, floating
    var label: String { self == .desktop ? "デスクトップ（ウインドウの背面）" : "常に最前面" }
}
enum DisplayMode: String, CaseIterable { case used, remaining
    var label: String { self == .used ? "使用率（Claude アプリと同じ）" : "残り（Codex アプリと同じ）" }
}
enum GlassStyle: String, CaseIterable { case regular, clear, dark
    var label: String { ["regular": "ガラス", "clear": "クリアガラス", "dark": "ダーク"][rawValue]! }
}
enum MenuBarMode: String, CaseIterable { case character, characterNumbers, iconOnly, bars, stacked, session, both, worst
    var label: String {
        ["character": "キャラクター（残量で体が満ちる）", "characterNumbers": "キャラクター ＋ 2段の数字",
         "iconOnly": "リングのみ", "bars": "ミニバー", "stacked": "2段の数字",
         "session": "リング ＋ 5時間の %", "both": "リング ＋ 5時間と週間の %",
         "worst": "いちばん余裕のない1つだけ"][rawValue]!
    }
    /// The pixel mascot is Claude's, so these styles always show Claude.
    var isCharacter: Bool { self == .character || self == .characterNumbers }
}
enum CharacterColor: String, CaseIterable { case level, claude
    var label: String { self == .level ? "使用率で変化（色の段階は設定で編集）" : "Claude オレンジ（90% 以上で赤）" }
}
enum ProviderSelection: String, CaseIterable { case claude, codex, both
    var label: String { ["claude": "Claude のみ", "codex": "Codex のみ", "both": "Claude と Codex"][rawValue]! }
    var providers: [Provider] {
        switch self {
        case .claude: return [.claude]
        case .codex: return [.codex]
        case .both: return [.claude, .codex]
        }
    }
}
enum ColorMode: String, CaseIterable { case level, brand
    var label: String { self == .level ? "使用率で変化（水色 → 緑 → 紫 → 黄 → 橙 → 赤）" : "固定（サービスの色）" }
}

@MainActor
final class Settings: ObservableObject {
    static let shared = Settings()
    private let d = UserDefaults.standard

    @Published var showWidget: Bool        { didSet { d.set(showWidget, forKey: "showWidget") } }
    @Published var showWorkScene: Bool     { didSet { d.set(showWorkScene, forKey: "showWorkScene") } }
    /// The weekly breakdown and credits change rarely, so the widget leaves them to the panel by default.
    @Published var showWidgetDetails: Bool { didSet { d.set(showWidgetDetails, forKey: "showWidgetDetails") } }
    /// The Claude character's colour steps (editable in the panel).
    @Published var characterSteps: [CharacterStep] {
        didSet {
            d.set(try? JSONEncoder().encode(characterSteps), forKey: "characterSteps")
            CharacterScale.current = characterSteps
        }
    }
    @Published var widgetSize: WidgetSize  { didSet { d.set(widgetSize.rawValue, forKey: "widgetSize") } }
    @Published var placement: Placement    { didSet { d.set(placement.rawValue, forKey: "placement") } }
    @Published var displayMode: DisplayMode { didSet { d.set(displayMode.rawValue, forKey: "displayMode") } }
    @Published var glassStyle: GlassStyle  { didSet { d.set(glassStyle.rawValue, forKey: "glassStyle") } }
    @Published var menuBarMode: MenuBarMode { didSet { d.set(menuBarMode.rawValue, forKey: "menuBarMode") } }
    @Published var intervalMinutes: Int    { didSet { d.set(intervalMinutes, forKey: "intervalMinutes") } }
    @Published var autoCLIRefresh: Bool    { didSet { d.set(autoCLIRefresh, forKey: "autoCLIRefresh") } }
    @Published var providerSelection: ProviderSelection { didSet { d.set(providerSelection.rawValue, forKey: "providers") } }
    @Published var colorMode: ColorMode    { didSet { d.set(colorMode.rawValue, forKey: "colorMode") } }
    @Published var menuBarClaudeOnly: Bool { didSet { d.set(menuBarClaudeOnly, forKey: "menuBarClaudeOnly") } }
    @Published var characterColor: CharacterColor { didSet { d.set(characterColor.rawValue, forKey: "characterColor") } }

    /// Services the menu bar shows; Codex can still be checked in the dropdown.
    var menuBarProviders: [Provider] {
        menuBarMode.isCharacter || menuBarClaudeOnly ? [.claude] : providerSelection.providers
    }
    /// Everything that needs fetching: what the widget/menu shows plus what the menu bar shows.
    var activeProviders: [Provider] {
        Provider.allCases.filter { providerSelection.providers.contains($0) || menuBarProviders.contains($0) }
    }

    init() {
        d.register(defaults: ["showWidget": true, "showWorkScene": true, "showWidgetDetails": false, "widgetSize": "medium", "placement": "desktop",
                              "displayMode": "used", "glassStyle": "regular", "menuBarMode": "session",
                              "intervalMinutes": 5, "autoCLIRefresh": true, "providers": "both", "colorMode": "level",
                              "menuBarClaudeOnly": true, "characterColor": "level"])
        showWidget = d.bool(forKey: "showWidget")
        showWorkScene = d.bool(forKey: "showWorkScene")
        showWidgetDetails = d.bool(forKey: "showWidgetDetails")
        let steps = d.data(forKey: "characterSteps").flatMap { try? JSONDecoder().decode([CharacterStep].self, from: $0) }
            ?? CharacterScale.defaults
        characterSteps = steps
        CharacterScale.current = steps
        widgetSize = WidgetSize(rawValue: d.string(forKey: "widgetSize") ?? "") ?? .medium
        placement = Placement(rawValue: d.string(forKey: "placement") ?? "") ?? .desktop
        displayMode = DisplayMode(rawValue: d.string(forKey: "displayMode") ?? "") ?? .used
        glassStyle = GlassStyle(rawValue: d.string(forKey: "glassStyle") ?? "") ?? .regular
        menuBarMode = MenuBarMode(rawValue: d.string(forKey: "menuBarMode") ?? "") ?? .session
        intervalMinutes = max(2, d.integer(forKey: "intervalMinutes"))
        autoCLIRefresh = d.bool(forKey: "autoCLIRefresh")
        providerSelection = ProviderSelection(rawValue: d.string(forKey: "providers") ?? "") ?? .both
        colorMode = ColorMode(rawValue: d.string(forKey: "colorMode") ?? "") ?? .level
        menuBarClaudeOnly = d.bool(forKey: "menuBarClaudeOnly")
        characterColor = CharacterColor(rawValue: d.string(forKey: "characterColor") ?? "") ?? .level
    }
}
