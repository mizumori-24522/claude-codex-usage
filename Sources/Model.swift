import Foundation

// MARK: - Providers

enum Provider: String, Codable, CaseIterable, Identifiable {
    case claude, codex

    var id: String { rawValue }
    var name: String { self == .claude ? "Claude" : "Codex" }
    var usageURL: URL {
        URL(string: self == .claude ? "https://claude.ai/settings/usage" : "https://chatgpt.com/codex/settings/usage")!
    }
}

// MARK: - Snapshot

struct UsageWindow: Codable, Equatable {
    var utilization: Double          // 0...100, used
    var resetsAt: Date?
}

struct NamedWindow: Codable, Equatable, Identifiable {
    var id: String
    var name: String
    var window: UsageWindow
}

struct CreditInfo: Codable, Equatable {
    var limit: Double
    var remaining: Double
    var expiresAt: Date?
}

struct BreakdownRow: Codable, Equatable, Identifiable {
    var id: String
    var name: String
    var percent: Double
}

struct UsageSnapshot: Codable, Equatable {
    var fiveHour: UsageWindow?
    var sevenDay: UsageWindow?
    var extraWeekly: [NamedWindow] = []
    var credit: CreditInfo?
    var breakdown: [BreakdownRow] = []
    var plan: String?
    var fetchedAt: Date
    /// Codex: free "full reset" grants still available.
    var resetCredits: Int?
    /// Claude: when the CLI's login runs out (refreshing does not extend it; `claude auth login` does).
    var loginExpiresAt: Date?
}

// MARK: - Errors

enum GaugeError: LocalizedError {
    case noCredentials, tokenExpired, unauthorized, rateLimited(TimeInterval?), http(Int), badResponse, network, cliMissing, cliFailed
    case codexMissing, codexNotLoggedIn, codexFailed

    var errorDescription: String? {
        switch self {
        case .noCredentials:    return "Claude Code のログイン情報がありません"
        case .tokenExpired:     return "トークン期限切れ"
        case .unauthorized:     return "認証エラー（claude で再ログイン）"
        case .rateLimited:      return "混雑中・しばらくして自動で再取得"
        case .http(let c):      return "サーバーエラー (\(c))"
        case .badResponse:      return "応答を解析できません"
        case .network:          return "オフライン"
        case .cliMissing:       return "claude CLI が見つかりません"
        case .cliFailed:        return "CLI でのトークン更新に失敗"
        case .codexMissing:     return "codex CLI が見つかりません"
        case .codexNotLoggedIn: return "Codex にログインしていません"
        case .codexFailed:      return "Codex から取得できません"
        }
    }
}

// MARK: - Claude parsing

enum UsageParser {
    static func date(_ any: Any?) -> Date? {
        guard var s = any as? String, !s.isEmpty else { return nil }
        // "2026-09-26T05:50:00.236110+00:00" — ISO8601DateFormatter can't take microseconds.
        if let r = s.range(of: #"\.\d+"#, options: .regularExpression) { s.removeSubrange(r) }
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: s)
    }

    static func number(_ any: Any?) -> Double? { (any as? NSNumber)?.doubleValue }

    static func window(_ any: Any?) -> UsageWindow? {
        guard let d = any as? [String: Any], let u = number(d["utilization"]) else { return nil }
        return UsageWindow(utilization: u, resetsAt: date(d["resets_at"]))
    }

    static func parse(_ data: Data, plan: String?) throws -> UsageSnapshot {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              root.keys.contains("five_hour") || root.keys.contains("seven_day")
        else { throw GaugeError.badResponse }

        var snap = UsageSnapshot(fiveHour: window(root["five_hour"]),
                                 sevenDay: window(root["seven_day"]),
                                 plan: plan,
                                 fetchedAt: Date())

        let perModel = [("seven_day_opus", "Opus"), ("seven_day_sonnet", "Sonnet"),
                        ("seven_day_cowork", "Cowork"), ("seven_day_routines", "Routines")]
        for (key, name) in perModel {
            if let w = window(root[key]) { snap.extraWeekly.append(NamedWindow(id: key, name: name, window: w)) }
        }

        // Credit pools come back under code-named keys, so look for any object carrying a dollar limit.
        for (_, value) in root {
            guard let d = value as? [String: Any], let limit = number(d["limit_dollars"]), limit > 0 else { continue }
            let remaining = number(d["remaining_dollars"]) ?? max(0, limit - (number(d["used_dollars"]) ?? 0))
            if snap.credit == nil || limit > snap.credit!.limit {
                snap.credit = CreditInfo(limit: limit, remaining: remaining, expiresAt: date(d["resets_at"]))
            }
        }

        if let b = root["seven_day_breakdown"] as? [String: Any], let rows = b["rows"] as? [[String: Any]] {
            snap.breakdown = rows.compactMap { r in
                guard let key = r["key"] as? String, let p = number(r["percent"]) else { return nil }
                return BreakdownRow(id: key, name: (r["display_name"] as? String) ?? key, percent: p)
            }
        }
        return snap
    }
}

// MARK: - Codex parsing (`account/rateLimits/read` result)

enum CodexParser {
    static func parse(_ result: [String: Any]) throws -> UsageSnapshot {
        guard let rl = result["rateLimits"] as? [String: Any] else { throw GaugeError.badResponse }

        // primary is normally the 5-hour lane and secondary the weekly one; go by duration to be sure.
        var five: UsageWindow?, week: UsageWindow?
        for key in ["primary", "secondary"] {
            guard let d = rl[key] as? [String: Any], let used = UsageParser.number(d["usedPercent"]) else { continue }
            let resets = UsageParser.number(d["resetsAt"]).map { Date(timeIntervalSince1970: $0) }
            let w = UsageWindow(utilization: used, resetsAt: resets)
            let minutes = UsageParser.number(d["windowDurationMins"]) ?? (key == "primary" ? 300 : 10080)
            if minutes <= 24 * 60 { five = five ?? w } else { week = week ?? w }
        }

        var snap = UsageSnapshot(fiveHour: five, sevenDay: week, plan: planName(rl["planType"] as? String), fetchedAt: Date())
        if let rc = result["rateLimitResetCredits"] as? [String: Any], let n = UsageParser.number(rc["availableCount"]) {
            snap.resetCredits = Int(n)
        }
        return snap
    }

    static func planName(_ raw: String?) -> String? {
        guard let raw, raw != "unknown" else { return nil }
        let known = ["free": "Free", "go": "Go", "plus": "Plus", "pro": "Pro", "prolite": "Pro Lite",
                     "team": "Team", "business": "Business", "enterprise": "Enterprise", "edu": "Edu"]
        return known[raw] ?? raw.replacingOccurrences(of: "_", with: " ").capitalized
    }
}
