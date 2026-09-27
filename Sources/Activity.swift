import AppKit
import Combine
import Foundation

enum WorkPhase: String, Equatable {
    case idle, working, waiting, finished, unknown
}

struct WorkActivity: Equatable {
    var phase: WorkPhase
    var sessionCount: Int
    var detail: String
    var changedAt: Date
    /// The most recent completed turn across this service's sessions.
    var lastFinishedAt: Date?
    /// Set while that completion has not been looked at yet (like an unread dot in the app).
    var unseenSince: Date?

    init(phase: WorkPhase = .unknown, sessionCount: Int = 0,
         detail: String = "状態を確認しています", changedAt: Date = Date(),
         lastFinishedAt: Date? = nil, unseenSince: Date? = nil) {
        self.phase = phase
        self.sessionCount = sessionCount
        self.detail = detail
        self.changedAt = changedAt
        self.lastFinishedAt = lastFinishedAt
        self.unseenSince = unseenSince
    }

    /// An unseen completion only matters while nothing new is running.
    var pendingCompletion: Date? { phase == .working || phase == .waiting ? nil : unseenSince }
}

/// Reads only local session events. App launch and usage refreshes are not work events.
@MainActor
final class WorkActivityStore: ObservableObject {
    static let shared = WorkActivityStore()
    @Published private(set) var states: [Provider: WorkActivity] = Dictionary(
        uniqueKeysWithValues: Provider.allCases.map { ($0, WorkActivity()) })

    private let scanner = WorkActivityScanner()
    private let queue = DispatchQueue(label: "local.claudecodexusage.activity", qos: .utility)
    private var polling: Task<Void, Never>?
    private var latest: [Provider: WorkActivity] = [:]
    /// Completions after these moments count as unseen. Starts at launch, so older ones are ignored.
    private var seenAt: [Provider: Date] = [:]
    private var activationObserver: NSObjectProtocol?

    /// What the ChatGPT app shows (when that detection is switched on).
    @Published private(set) var chatGPT: ChatGPTWatcher.State = .off
    private var chatGPTBusySince: Date?
    private var chatGPTFinishedAt: Date?
    private var tick = 0
    /// Whether to watch the ChatGPT app; supplied by the app so this file stays free of settings.
    var watchChatGPT: () -> Bool = { false }

    static func bundleID(_ p: Provider) -> String { p == .codex ? "com.openai.codex" : "com.anthropic.claudefordesktop" }

    /// Marks completions as seen, e.g. after a click on the widget.
    func markSeen(_ providers: [Provider] = Provider.allCases) {
        for p in providers { seenAt[p] = Date() }
        publish()
    }

    /// Folds what the ChatGPT app shows into Codex: its cloud work leaves no local log.
    private func withChatGPT(_ base: [Provider: WorkActivity], now: Date) -> [Provider: WorkActivity] {
        guard var codex = base[.codex] else { return base }
        var result = base
        if chatGPT == .busy, codex.phase != .working, codex.phase != .waiting {
            codex.phase = .working
            codex.detail = "ChatGPT アプリで作業中"
            codex.changedAt = chatGPTBusySince ?? now
            codex.sessionCount = max(codex.sessionCount, 1)
        } else if let finished = chatGPTFinishedAt, now.timeIntervalSince(finished) <= 5,
                  codex.phase != .working, codex.phase != .waiting {
            codex.phase = .finished
            codex.detail = "ChatGPT アプリの作業が完了しました"
            codex.changedAt = finished
        }
        if let finished = chatGPTFinishedAt, finished > (codex.lastFinishedAt ?? .distantPast) {
            codex.lastFinishedAt = finished
        }
        result[.codex] = codex
        return result
    }

    private func publish() {
        let now = Date()
        let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier?.lowercased()
        let latest = withChatGPT(self.latest, now: now)
        var merged = latest
        for (p, activity) in latest {
            var a = activity
            // New work supersedes an old result; looking at the app while it finishes counts as seen.
            if a.phase == .working || a.phase == .waiting || front == Self.bundleID(p) { seenAt[p] = now }
            if let finished = a.lastFinishedAt, finished > (seenAt[p] ?? .distantFuture) {
                a.unseenSince = finished
            } else {
                a.unseenSince = nil
            }
            merged[p] = a
        }
        if states != merged { states = merged }
    }

    func start() {
        guard polling == nil else { return }
        let launched = Date()
        for p in Provider.allCases where seenAt[p] == nil { seenAt[p] = launched }
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            let bundle = app?.bundleIdentifier?.lowercased()
            Task { @MainActor in
                guard let self else { return }
                let opened = Provider.allCases.filter { Self.bundleID($0) == bundle }
                if !opened.isEmpty { self.markSeen(opened) }
            }
        }
        let scanner = self.scanner
        let queue = self.queue
        polling = Task { [weak self] in
            while !Task.isCancelled {
                // NSWorkspace gives GUI liveness without inspecting a conversation or a window.
                let apps = NSWorkspace.shared.runningApplications
                let guiProviders = Set(Provider.allCases.filter { provider in
                    apps.contains { app in
                        let name = app.localizedName?.lowercased() ?? ""
                        let bundle = app.bundleIdentifier?.lowercased() ?? ""
                        return provider == .codex
                            ? name == "codex" || bundle == "com.openai.codex"
                            : name == "claude" || bundle == "com.anthropic.claudefordesktop"
                    }
                })
                guard let owner = self else { break }
                owner.tick += 1
                let watchEnabled = owner.watchChatGPT()
                let watchApp = watchEnabled && owner.tick % 2 == 0
                let (result, appState) = await withCheckedContinuation { continuation in
                    queue.async {
                        continuation.resume(returning: (scanner.poll(guiProviders: guiProviders),
                                                        watchApp ? ChatGPTWatcher.check() : nil))
                    }
                }
                guard !Task.isCancelled, let self else { break }
                if !watchEnabled {
                    self.updateChatGPT(.off)
                } else if let appState {
                    self.updateChatGPT(appState)
                }
                self.latest = result
                self.publish()
                // The scanner runs off the main thread; one scan at a time, even after a slow read.
                do { try await Task.sleep(nanoseconds: 2_000_000_000) } catch { break }
            }
        }
    }

    private func updateChatGPT(_ state: ChatGPTWatcher.State) {
        let now = Date()
        if state == .busy, chatGPT != .busy { chatGPTBusySince = now }
        // Busy → anything else (idle, app closed) means that reply finished.
        if chatGPT == .busy, state != .busy, state != .off { chatGPTFinishedAt = now }
        if chatGPT != state { chatGPT = state }
    }

    func stop() {
        polling?.cancel()
        polling = nil
        if let activationObserver { NSWorkspace.shared.notificationCenter.removeObserver(activationObserver) }
        activationObserver = nil
    }
}

// MARK: - Deterministic transitions (no message text, tool input, or output is retained)

struct WorkSessionSignal {
    private(set) var phase: WorkPhase = .unknown
    private(set) var lastEvidenceAt: Date?
    private(set) var lastFinishedAt: Date?
    static let abandonedAfter: TimeInterval = 30 * 60

    mutating func consume(_ record: [String: Any], provider: Provider) {
        guard let timestamp = UsageParser.date(record["timestamp"]),
              timestamp >= (lastEvidenceAt ?? .distantPast),
              let type = record["type"] as? String else { return }
        let next = provider == .codex ? codexPhase(record, type: type) : claudePhase(record, type: type)
        guard let next else { return }
        phase = next
        lastEvidenceAt = timestamp
        if next == .finished { lastFinishedAt = timestamp }
    }

    func effectivePhase(at now: Date) -> WorkPhase {
        guard let lastEvidenceAt else { return .unknown }
        let age = now.timeIntervalSince(lastEvidenceAt)
        guard age >= -30 else { return .unknown }
        // A turn that went silent is uncertain for a while (a long command may still be
        // running), but after half an hour it is treated as abandoned rather than letting one
        // interrupted session mark the whole service as undetected for the rest of the day.
        switch phase {
        case .working: return age <= 180 ? .working : (age <= Self.abandonedAfter ? .unknown : .idle)
        case .waiting: return age <= 600 ? .waiting : (age <= Self.abandonedAfter ? .unknown : .idle)
        case .finished: return age <= 5 ? .finished : .idle
        case .idle, .unknown: return phase
        }
    }

    private func codexPhase(_ record: [String: Any], type: String) -> WorkPhase? {
        guard let payload = record["payload"] as? [String: Any] else { return nil }
        let event = payload["type"] as? String ?? ""
        if type == "event_msg" {
            switch event {
            case "task_started", "turn_started", "user_message": return .working
            case "task_complete", "turn_completed": return .finished
            case "turn_aborted", "task_aborted": return .idle
            case "exec_approval_request", "apply_patch_approval_request", "request_user_input": return .waiting
            case "approval_response": return .working
            case "item_completed":
                guard let item = payload["item"] as? [String: Any] else { return nil }
                if item["phase"] as? String == "final_answer" { return .finished }
                // Completing the displayed question itself does not mean the user answered it.
                if let tool = item["tool"] as? String, isQuestion(tool) { return nil }
                let kind = item["type"] as? String ?? ""
                return ["Reasoning", "CommandExecution", "FileChange", "McpToolCall", "Extension", "AgentMessage"].contains(kind)
                    ? .working : nil
            default: return nil
            }
        }
        guard type == "response_item" else { return nil }
        if event == "message", payload["role"] as? String == "assistant" {
            switch payload["phase"] as? String {
            case "final_answer": return .finished
            case "commentary": return .working
            default: return nil
            }
        }
        if ["function_call", "custom_tool_call"].contains(event) {
            return isQuestion(payload["name"] as? String ?? "") ? .waiting : .working
        }
        if ["function_call_output", "custom_tool_call_output", "reasoning"].contains(event) { return .working }
        return nil
    }

    private func claudePhase(_ record: [String: Any], type: String) -> WorkPhase? {
        // Metadata, title changes, queue edits and file snapshots are not execution evidence.
        guard ["user", "assistant"].contains(type),
              record["isMeta"] as? Bool != true,
              let message = record["message"] as? [String: Any] else { return nil }
        let blocks = message["content"] as? [[String: Any]] ?? []
        if type == "user" { return .working } // User submission or a completed tool result.
        if blocks.contains(where: { $0["type"] as? String == "tool_use" && $0["name"] as? String == "AskUserQuestion" }) {
            return .waiting
        }
        switch message["stop_reason"] as? String {
        case "end_turn", "stop_sequence", "max_tokens", "refusal": return .finished
        case "tool_use": return .working
        default:
            return blocks.contains { ["thinking", "text", "tool_use"].contains($0["type"] as? String ?? "") }
                ? .working : nil
        }
    }

    private func isQuestion(_ name: String) -> Bool {
        name == "request_user_input" || name.hasSuffix("__request_user_input") || name.hasSuffix(".request_user_input")
    }
}

// MARK: - Bounded incremental JSONL reads

final class WorkSessionTail {
    let url: URL
    let provider: Provider
    var signal = WorkSessionSignal()
    private var offset: UInt64 = 0
    private var remainder = Data()
    private var discardingLongLine = false
    private var identity: UInt64?
    private var initialized = false
    private(set) var readFailed = false
    private let readLimit = 512 * 1024

    init(url: URL, provider: Provider) { self.url = url; self.provider = provider }

    func update() {
        do {
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            let size = (attributes[.size] as? NSNumber)?.uint64Value ?? 0
            let inode = (attributes[.systemFileNumber] as? NSNumber)?.uint64Value
            if size < offset || (identity != nil && inode != identity) {
                offset = 0; initialized = false; remainder = Data(); signal = WorkSessionSignal()
            }
            identity = inode
            guard !initialized || size > offset else { readFailed = false; return }
            let file = try FileHandle(forReadingFrom: url)
            defer { try? file.close() }
            // Bootstrap near the end and drop a partial first line. A large backlog is also
            // resynchronized at the tail; state is observational, not a full history replay.
            if !initialized || size - offset > UInt64(readLimit) {
                let start = size > UInt64(readLimit) ? size - UInt64(readLimit) : 0
                offset = start
                remainder = Data()
                discardingLongLine = start > 0
                initialized = true
            }
            try file.seek(toOffset: offset)
            let bytes = try file.read(upToCount: readLimit) ?? Data()
            offset += UInt64(bytes.count)
            var buffer = remainder
            buffer.append(bytes)
            var start = buffer.startIndex
            while let end = buffer[start...].firstIndex(of: 10) {
                let line = buffer[start..<end]
                if !discardingLongLine, line.count <= readLimit,
                   let record = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any] {
                    signal.consume(record, provider: provider)
                }
                discardingLongLine = false
                start = buffer.index(after: end)
            }
            remainder = Data(buffer[start...])
            if remainder.count > readLimit { remainder = Data(); discardingLongLine = true }
            readFailed = false
        } catch {
            // Never keep animating a cached working state when its source becomes unreadable.
            readFailed = true
        }
    }
}

private enum WorkProcessLiveness { case running, stopped, unavailable }

// The store accesses this mutable scanner exclusively on its serial utility queue.
final class WorkActivityScanner: @unchecked Sendable {
    private let home: URL
    private var tails: [String: WorkSessionTail] = [:]
    private var previous: [Provider: WorkActivity] = [:]
    private var lastDiscovery = Date.distantPast
    private var discoveryUnavailable: Set<Provider> = []
    private var lastProcessCheck = Date.distantPast
    private var cliProviders: Set<Provider> = []
    private var processCheckAvailable = false

    struct ProcessEntry { let pid: Int; let parent: Int; let name: String }
    private let listProcesses: () -> [ProcessEntry]?

    init(home: URL = FileManager.default.homeDirectoryForCurrentUser,
         listProcesses: @escaping () -> [ProcessEntry]? = WorkActivityScanner.systemProcesses) {
        self.home = home
        self.listProcesses = listProcesses
    }

    /// PID, parent PID and executable name straight from the kernel (no subprocess, no arguments).
    static func systemProcesses() -> [ProcessEntry]? {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0]
        var size = 0
        guard sysctl(&mib, u_int(mib.count), nil, &size, nil, 0) == 0, size > 0 else { return nil }
        let stride = MemoryLayout<kinfo_proc>.stride
        var procs = [kinfo_proc](repeating: kinfo_proc(), count: size / stride + 16)
        size = procs.count * stride
        guard sysctl(&mib, u_int(mib.count), &procs, &size, nil, 0) == 0 else { return nil }
        return procs.prefix(size / stride).map { p in
            let name = withUnsafeBytes(of: p.kp_proc.p_comm) { raw in
                String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
            }
            return ProcessEntry(pid: Int(p.kp_proc.p_pid), parent: Int(p.kp_eproc.e_ppid), name: name.lowercased())
        }
    }

    func poll(guiProviders: Set<Provider>, now: Date = Date()) -> [Provider: WorkActivity] {
        if now.timeIntervalSince(lastDiscovery) >= 20 { discover(at: now) }
        if now.timeIntervalSince(lastProcessCheck) >= 4 { inspectProcesses(at: now) }
        for tail in tails.values { tail.update() }
        var result: [Provider: WorkActivity] = [:]
        for provider in Provider.allCases {
            let live: WorkProcessLiveness = guiProviders.contains(provider) || cliProviders.contains(provider)
                ? .running : (processCheckAvailable ? .stopped : .unavailable)
            let sessions = tails.values.filter { $0.provider == provider }
            let phases = sessions.map { $0.readFailed ? WorkPhase.unknown : $0.signal.effectivePhase(at: now) }
            let phase: WorkPhase
            let count: Int
            if live == .running, phases.contains(.working) {
                phase = .working; count = phases.filter { $0 == .working }.count
            } else if live == .running, phases.contains(.waiting) {
                phase = .waiting; count = phases.filter { $0 == .waiting }.count
            } else if phases.contains(.finished) {
                phase = .finished; count = phases.filter { $0 == .finished }.count
            } else if live == .stopped {
                phase = .idle; count = 0
            } else if live == .unavailable || discoveryUnavailable.contains(provider) || phases.isEmpty || phases.contains(.unknown) {
                phase = .unknown; count = 0
            } else {
                phase = .idle; count = 0
            }
            let details: [WorkPhase: String] = [.idle: "待機中", .working: "作業中", .waiting: "入力・確認待ち",
                                              .finished: "作業が完了しました", .unknown: "作業状態を確認できません"]
            let old = previous[provider]
            let changedAt = old?.phase == phase ? old!.changedAt : now
            let finished = sessions.compactMap { $0.readFailed ? nil : $0.signal.lastFinishedAt }.max()
            result[provider] = WorkActivity(phase: phase, sessionCount: count, detail: details[phase]!, changedAt: changedAt,
                                            lastFinishedAt: finished)
        }
        previous = result
        return result
    }

    private func discover(at now: Date) {
        lastDiscovery = now
        discoveryUnavailable = []
        var selected: [String: WorkSessionTail] = [:]
        for provider in Provider.allCases {
            let relative = provider == .codex ? ".codex/sessions" : ".claude/projects"
            let root = home.appendingPathComponent(relative, isDirectory: true)
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: root.path, isDirectory: &isDirectory) else { continue }
            var failed = false
            var candidates: [URL: Date] = [:]
            // Start at current date folders so years of old logs cannot consume the traversal
            // budget before a new turn is reached. Afterwards inspect the broader tree to find
            // older sessions that were resumed today. Both UTC and local dates are supported.
            var searchRoots: [URL] = []
            if provider == .codex {
                let formatter = DateFormatter()
                formatter.locale = Locale(identifier: "en_US_POSIX")
                formatter.dateFormat = "yyyy/MM/dd"
                for zone in [TimeZone.current, TimeZone(secondsFromGMT: 0)!] {
                    formatter.timeZone = zone
                    for delta in [0.0, -86400.0] {
                        let folder = root.appendingPathComponent(formatter.string(from: now.addingTimeInterval(delta)), isDirectory: true)
                        if FileManager.default.fileExists(atPath: folder.path), !searchRoots.contains(folder) { searchRoots.append(folder) }
                    }
                }
            }
            searchRoots.append(root)
            for searchRoot in searchRoots {
                guard let enumerator = FileManager.default.enumerator(at: searchRoot,
                    includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey, .isSymbolicLinkKey],
                    options: [.skipsHiddenFiles], errorHandler: { _, _ in failed = true; return true }) else {
                    failed = true; continue
                }
                var visits = 0
                for case let url as URL in enumerator {
                    visits += 1
                    if visits > (searchRoot == root ? 6000 : 1000) { failed = true; break }
                    if ["memory", "node_modules", ".git"].contains(url.lastPathComponent) { enumerator.skipDescendants(); continue }
                    guard url.pathExtension == "jsonl", let values = try? url.resourceValues(forKeys:
                        [.contentModificationDateKey, .isRegularFileKey, .isSymbolicLinkKey]),
                          values.isRegularFile == true, values.isSymbolicLink != true,
                          let modified = values.contentModificationDate,
                          now.timeIntervalSince(modified) < 24 * 60 * 60 else { continue }
                    candidates[url] = modified
                }
            }
            if failed { discoveryUnavailable.insert(provider) }
            // More than 24 sessions in a day is ordinary; only the most recent ones matter.
            for (url, _) in candidates.sorted(by: { $0.value > $1.value }).prefix(24) {
                selected[url.path] = tails[url.path] ?? WorkSessionTail(url: url, provider: provider)
            }
        }
        tails = selected
    }

    private func inspectProcesses(at now: Date) {
        lastProcessCheck = now
        cliProviders = []
        processCheckAvailable = false
        // Only PID, parent PID and executable name; command arguments can contain prompts.
        guard let entries = listProcesses(), !entries.isEmpty else { return }
        processCheckAvailable = true
        let parents = Dictionary(uniqueKeysWithValues: entries.map { ($0.pid, $0.parent) })
        let usageApps = Set(entries.filter { $0.name.hasPrefix("claudecodexusage") }.map(\.pid)).union([Int(ProcessInfo.processInfo.processIdentifier)])
        for entry in entries {
            var ancestor = entry.pid
            var excluded = false
            for _ in 0..<32 {
                if usageApps.contains(ancestor) { excluded = true; break }
                guard let next = parents[ancestor], next > 1, next != ancestor else { break }
                ancestor = next
            }
            guard !excluded else { continue }
            if ["codex", "codex-app-server"].contains(entry.name) { cliProviders.insert(.codex) }
            if entry.name == "claude" { cliProviders.insert(.claude) }
        }
    }
}
