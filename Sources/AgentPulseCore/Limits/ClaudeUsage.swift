import Foundation

/// Claude subscription usage (`GET /api/oauth/usage`).
public enum ClaudeUsage {
    // MARK: Parsing (pure)

    /// Parses the usage response into windows, without caring about the exact keys.
    /// Any top-level object holding a numeric `utilization` becomes a window.
    public static func parse(data: Data) -> [UsageWindow]? {
        guard
            let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }

        // Current responses list every limit Claude Code shows ("session", "weekly_all", ...).
        if let limits = root["limits"] as? [[String: Any]] {
            let windows = limits.compactMap { limit -> UsageWindow? in
                guard let kind = limit["kind"] as? String,
                      let percent = number(limit["percent"])
                else { return nil }
                return UsageWindow(
                    id: kind,
                    label: label(forKind: kind),
                    usedPercent: percent,
                    resetsAt: ISO8601.parse(limit["resets_at"] as? String)
                )
            }
            if !windows.isEmpty { return windows }
        }

        // Older responses: top-level `five_hour` / `seven_day` / ... objects.
        var windows: [UsageWindow] = []
        for (key, value) in root {
            guard
                let object = value as? [String: Any],
                let utilization = number(object["utilization"])
            else { continue }

            let resetsAt = ISO8601.parse(object["resets_at"] as? String)
            windows.append(
                UsageWindow(
                    id: key,
                    label: label(forKey: key),
                    usedPercent: utilization,
                    resetsAt: resetsAt
                )
            )
        }

        windows.sort { lhs, rhs in
            let left = rank(lhs.id)
            let right = rank(rhs.id)
            if left != right { return left < right }
            return lhs.id < rhs.id
        }
        return windows
    }

    public static func parse(json: String) -> [UsageWindow]? {
        parse(data: Data(json.utf8))
    }

    /// `limits[].kind` → the names Claude Code uses (`weekly_sonnet` → `週・Sonnet`).
    public static func label(forKind kind: String) -> String {
        switch kind {
        case "session": return "セッション"
        case "weekly_all": return "週・全体"
        default:
            guard kind.hasPrefix("weekly_") else { return kind }
            return "週・" + kind.dropFirst("weekly_".count).capitalized
        }
    }

    /// `five_hour` → `5h`, `seven_day_opus` → `7d Opus`.
    public static func label(forKey key: String) -> String {
        let tokens = key.split(separator: "_").map(String.init)
        guard tokens.count >= 2,
              let count = numberWords[tokens[0]],
              let unit = unitWords[tokens[1]]
        else {
            return tokens.map { $0.capitalized }.joined(separator: " ")
        }

        let suffix = tokens.dropFirst(2).map { $0.capitalized }.joined(separator: " ")
        return suffix.isEmpty ? count + unit : "\(count)\(unit) \(suffix)"
    }

    private static let numberWords: [String: String] = [
        "one": "1", "two": "2", "three": "3", "four": "4", "five": "5",
        "seven": "7", "ten": "10", "fourteen": "14", "thirty": "30", "sixty": "60",
    ]

    private static let unitWords: [String: String] = [
        "minute": "m", "hour": "h", "day": "d", "week": "w", "month": "mo",
    ]

    private static func rank(_ key: String) -> Int {
        switch key {
        case "five_hour": 0
        case "seven_day": 1
        default: 2
        }
    }

    private static func number(_ value: Any?) -> Double? {
        if let value = value as? Double { return value }
        if let value = value as? Int { return Double(value) }
        if let value = value as? NSNumber { return value.doubleValue }
        if let value = value as? String { return Double(value) }
        return nil
    }

    // MARK: I/O

    private static let credentialsService = "Claude Code-credentials"
    private static let usageURL = URL(string: "https://api.anthropic.com/api/oauth/usage")!

    /// Claude Code's OAuth credentials. Read-only: never refreshed or written back here,
    /// since a refresh would rotate the token Claude Code itself depends on.
    public struct Credentials: Sendable {
        public let accessToken: String
        public let expiresAt: Date?
    }

    public static var credentialsFile: URL {
        FileManager.default.homeDirectoryForCurrentUser.appending(path: ".claude/.credentials.json")
    }

    /// `~/.claude/.credentials.json` (Linux / older installs), else the macOS login keychain.
    public static func loadCredentials() -> Credentials? {
        if let data = try? Data(contentsOf: credentialsFile),
           let credentials = parseCredentials(data) {
            return credentials
        }
        let result = Shell.run(
            "/usr/bin/security",
            ["find-generic-password", "-s", credentialsService, "-w"],
            timeout: 5
        )
        guard result.succeeded else { return nil }
        return parseCredentials(Data(result.stdout.utf8))
    }

    public static func parseCredentials(_ data: Data) -> Credentials? {
        guard
            let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let oauth = root["claudeAiOauth"] as? [String: Any],
            let token = oauth["accessToken"] as? String,
            !token.isEmpty
        else { return nil }
        let expiresAt = number(oauth["expiresAt"]).map { Date(timeIntervalSince1970: $0 / 1_000) }
        return Credentials(accessToken: token, expiresAt: expiresAt)
    }

    public static func fetch() async -> ProviderUsage {
        guard let credentials = loadCredentials() else {
            return ProviderUsage(
                id: .claude,
                error: "認証情報が見つかりません。Claude Code でログインしてください。"
            )
        }
        if let expiresAt = credentials.expiresAt, expiresAt < Date() {
            return ProviderUsage(
                id: .claude,
                error: "トークンの期限切れ。Claude Code を起動すると更新されます。"
            )
        }
        let token = credentials.accessToken

        var request = URLRequest(url: usageURL)
        request.httpMethod = "GET"
        request.timeoutInterval = 15
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0

            switch status {
            case 200...299:
                guard let windows = parse(data: data) else {
                    return ProviderUsage(id: .claude, error: "応答を解釈できませんでした。")
                }
                return ProviderUsage(id: .claude, windows: windows, asOf: Date())
            case 429:
                return ProviderUsage(id: .claude, error: "API 制限中 (HTTP 429)。自動で再試行します")
            case 401:
                return ProviderUsage(
                    id: .claude,
                    error: "Claude Code で再ログインしてください。"
                )
            default:
                return ProviderUsage(id: .claude, error: "取得に失敗しました (HTTP \(status))")
            }
        } catch {
            return ProviderUsage(id: .claude, error: "取得に失敗しました（オフライン？）")
        }
    }
}
