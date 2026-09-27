import Foundation

// Standalone deterministic checks, with no API calls or real conversation fixtures.
// swiftc -module-cache-path /tmp/usage-activity-module-cache -swift-version 5 \
//   -parse-as-library Sources/Model.swift Sources/Activity.swift Tests/ActivityChecks.swift \
//   -framework AppKit -o /tmp/usage-activity-checks && /tmp/usage-activity-checks
// Service.swift is deliberately excluded; process inspection is stubbed per scanner below.

@main
struct ActivityChecks {
    static func main() throws {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let formatter = ISO8601DateFormatter()
        func time(_ delta: TimeInterval) -> String { formatter.string(from: start.addingTimeInterval(delta)) }
        func codex(_ event: String, at delta: TimeInterval = 0) -> [String: Any] {
            ["type": "event_msg", "timestamp": time(delta), "payload": ["type": event]]
        }
        func response(_ kind: String, extra: [String: Any] = [:], at delta: TimeInterval = 0) -> [String: Any] {
            var payload = extra; payload["type"] = kind
            return ["type": "response_item", "timestamp": time(delta), "payload": payload]
        }
        func claude(_ type: String, reason: String? = nil, blocks: [[String: Any]] = [], at delta: TimeInterval = 0) -> [String: Any] {
            var message: [String: Any] = ["content": blocks]
            if let reason { message["stop_reason"] = reason }
            return ["type": type, "timestamp": time(delta), "message": message]
        }
        var assertions = 0
        func check(_ value: Bool, _ description: String) {
            precondition(value, description); assertions += 1
        }

        var signal = WorkSessionSignal()
        signal.consume(codex("thread_settings_applied"), provider: .codex)
        check(signal.lastEvidenceAt == nil, "settings changes must not signal work")
        signal.consume(codex("task_started"), provider: .codex)
        check(signal.effectivePhase(at: start) == .working, "explicit start")
        signal.consume(response("function_call", extra: ["name": "functions.request_user_input"], at: 1), provider: .codex)
        check(signal.phase == .waiting, "question waits for the user")
        signal.consume(response("function_call_output", at: 2), provider: .codex)
        check(signal.phase == .working, "answered question resumes work")
        signal.consume(codex("task_complete", at: 3), provider: .codex)
        check(signal.phase == .finished, "explicit completion")
        signal.consume(codex("task_started", at: 1), provider: .codex)
        check(signal.phase == .finished, "out-of-order records cannot undo completion")
        check(signal.effectivePhase(at: start.addingTimeInterval(9)) == .idle, "completion is brief")
        signal.consume(codex("task_started", at: 10), provider: .codex)
        check(signal.effectivePhase(at: start.addingTimeInterval(191)) == .unknown, "silent work becomes unknown")
        check(signal.effectivePhase(at: start.addingTimeInterval(10 + 31 * 60)) == .idle, "abandoned work stops counting after 30 minutes")
        signal.consume(codex("task_aborted", at: 11), provider: .codex)
        check(signal.phase == .idle, "aborted turn is idle")
        var malformed = codex("task_started", at: 12); malformed.removeValue(forKey: "timestamp")
        signal.consume(malformed, provider: .codex)
        check(signal.phase == .idle, "records without timestamps are ignored")
        signal.consume(response("message", extra: ["role": "assistant", "phase": "final_answer"], at: 12), provider: .codex)
        check(signal.phase == .finished, "desktop final answer is completion")
        signal.consume(response("message", extra: ["role": "user"], at: 13), provider: .codex)
        check(signal.phase == .finished, "history user message alone is not a Codex turn")
        signal.consume(codex("task_started", at: 1000), provider: .codex)
        check(signal.effectivePhase(at: start) == .unknown, "future event timestamp is not trusted")

        var anthropic = WorkSessionSignal()
        anthropic.consume(claude("user"), provider: .claude)
        check(anthropic.phase == .working, "Claude submission starts a turn")
        anthropic.consume(claude("assistant", reason: "tool_use", blocks: [["type": "tool_use", "name": "Bash"]], at: 1), provider: .claude)
        check(anthropic.phase == .working, "tool execution stays active")
        anthropic.consume(claude("assistant", reason: "tool_use", blocks: [["type": "tool_use", "name": "AskUserQuestion"]], at: 2), provider: .claude)
        check(anthropic.phase == .waiting, "Claude question waits")
        anthropic.consume(claude("user", blocks: [["type": "tool_result"]], at: 3), provider: .claude)
        check(anthropic.phase == .working, "Claude question response resumes")
        anthropic.consume(claude("assistant", reason: "end_turn", at: 4), provider: .claude)
        check(anthropic.phase == .finished, "end_turn completes")
        var meta = claude("user", at: 5); meta["isMeta"] = true
        anthropic.consume(meta, provider: .claude)
        check(anthropic.phase == .finished, "meta user record does not restart")

        let fixture = FileManager.default.temporaryDirectory.appendingPathComponent("activity-check-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: fixture, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: fixture) }
        let file = fixture.appendingPathComponent("fixture.jsonl")
        func bytes(_ record: [String: Any], newline: Bool = true) throws -> Data {
            var data = try JSONSerialization.data(withJSONObject: record)
            if newline { data.append(10) }
            return data
        }
        try bytes(codex("task_started"), newline: false).write(to: file)
        let tail = WorkSessionTail(url: file, provider: .codex)
        tail.update()
        check(tail.signal.phase == .unknown, "partial lines wait for newline")
        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd(); try handle.write(contentsOf: Data([10]))
        tail.update()
        check(tail.signal.phase == .working, "partial line joins next read")
        try handle.write(contentsOf: Data("malformed\n".utf8))
        try handle.write(contentsOf: bytes(codex("task_complete", at: 1)))
        try handle.close()
        tail.update()
        check(tail.signal.phase == .finished, "malformed line does not lose next valid record")
        try Data().write(to: file)
        tail.update()
        check(tail.signal.phase == .unknown, "truncation resets stale state")
        var giant = Data(repeating: 120, count: 700_000); giant.append(10)
        giant.append(try bytes(codex("task_complete", at: 2)))
        try giant.write(to: file)
        tail.update()
        check(tail.signal.phase == .finished, "oversized row is skipped with bounded tail read")
        try FileManager.default.removeItem(at: file)
        tail.update()
        check(tail.readFailed, "unreadable source is marked unknown")

        // A real-looking session directory is isolated under temporary storage.
        let sessions = fixture.appendingPathComponent(".codex/sessions/2027/01/15")
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        let firstFile = sessions.appendingPathComponent("rollout.jsonl")
        try bytes(codex("task_started")).write(to: firstFile)
        try FileManager.default.setAttributes([.modificationDate: start], ofItemAtPath: firstFile.path)
        let scanner = WorkActivityScanner(home: fixture, listProcesses: { nil })
        let working = scanner.poll(guiProviders: [.codex], now: start)
        check(working[.codex]?.phase == .working && working[.codex]?.sessionCount == 1, "scanner aggregates a real event")
        let noClaudeEvents = scanner.poll(guiProviders: [.codex, .claude], now: start.addingTimeInterval(2))
        check(noClaudeEvents[.claude]?.phase == .unknown, "GUI app without local events is unknown")
        let secondFile = sessions.appendingPathComponent("second.jsonl")
        try bytes(codex("task_started", at: 20)).write(to: secondFile)
        try FileManager.default.setAttributes([.modificationDate: start.addingTimeInterval(20)], ofItemAtPath: secondFile.path)
        let two = scanner.poll(guiProviders: [.codex], now: start.addingTimeInterval(20))
        check(two[.codex]?.sessionCount == 2 && two[.codex]?.changedAt == working[.codex]?.changedAt,
              "multiple sessions aggregate without restarting phase animation")
        let stale = scanner.poll(guiProviders: [.codex], now: start.addingTimeInterval(201))
        check(stale[.codex]?.phase == .unknown, "running app cannot keep stale incomplete turns active")
        // One abandoned session must not hide the state of every other session.
        let abandonedFile = sessions.appendingPathComponent("abandoned.jsonl")
        try bytes(codex("task_started", at: -3 * 3600)).write(to: abandonedFile)
        try FileManager.default.setAttributes([.modificationDate: start.addingTimeInterval(300)], ofItemAtPath: abandonedFile.path)
        let doneFile = sessions.appendingPathComponent("done.jsonl")
        try bytes(codex("task_complete", at: 290)).write(to: doneFile)
        try FileManager.default.setAttributes([.modificationDate: start.addingTimeInterval(300)], ofItemAtPath: doneFile.path)
        let running = WorkActivityScanner(home: fixture, listProcesses: {
            [.init(pid: 10, parent: 1, name: "codex")]
        })
        let afterWork = running.poll(guiProviders: [], now: start.addingTimeInterval(2400))
        check(afterWork[.codex]?.phase == .idle, "an old interrupted session does not make an idle app undetected")

        // A busy day with many sessions is not a detection failure.
        for i in 0..<30 {
            let f = sessions.appendingPathComponent("busy-\(i).jsonl")
            try bytes(codex("task_complete", at: 2300)).write(to: f)
            try FileManager.default.setAttributes([.modificationDate: start.addingTimeInterval(2300)], ofItemAtPath: f.path)
        }
        let busy = WorkActivityScanner(home: fixture, listProcesses: { [.init(pid: 10, parent: 1, name: "codex")] })
        check(busy.poll(guiProviders: [], now: start.addingTimeInterval(2400))[.codex]?.phase == .idle, "more than 24 sessions stays idle")

        // The in-process table lists this very process without launching anything.
        let table = WorkActivityScanner.systemProcesses() ?? []
        check(table.contains { $0.pid == Int(ProcessInfo.processInfo.processIdentifier) }, "kernel process table is readable")
        print("Activity checks passed: \(assertions)")
    }
}
