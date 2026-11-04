import Foundation

/// Codex / GPT usage: live from the endpoint Codex's `/status` uses, with the newest rollout
/// logs as an offline fallback.
public enum CodexUsage {
    // MARK: Parsing (pure)

    /// Extracts the usage windows from one JSONL line that carries `rate_limits`.
    /// Returns `nil` when the line has no such payload.
    public static func parse(line: String, now: Date = Date()) -> [UsageWindow]? {
        guard line.contains("rate_limits") else { return nil }
        guard
            let data = line.data(using: .utf8),
            let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let limits = findRateLimits(in: root)
        else { return nil }

        var windows: [UsageWindow] = []
        for key in ["primary", "secondary"] {
            guard
                let entry = limits[key] as? [String: Any],
                let used = number(entry["used_percent"])
            else { continue }

            let minutes = number(entry["window_minutes"]).map { Int($0) }
            let resetsAt = number(entry["resets_at"]).map { Date(timeIntervalSince1970: $0) }

            var usedPercent = used
            var note: String?
            if let resetsAt, resetsAt <= now {
                usedPercent = 0
                note = "リセット済み（最新値未取得）"
            }

            windows.append(
                UsageWindow(
                    id: key,
                    label: DurationText.windowLabel(minutes: minutes),
                    usedPercent: usedPercent,
                    resetsAt: resetsAt,
                    note: note
                )
            )
        }

        return windows.isEmpty ? nil : windows
    }

    /// Searches `payload.rate_limits` first, then any nested `rate_limits` key.
    static func findRateLimits(in root: [String: Any]) -> [String: Any]? {
        if let payload = root["payload"] as? [String: Any],
           let limits = payload["rate_limits"] as? [String: Any] {
            return limits
        }
        if let limits = root["rate_limits"] as? [String: Any] {
            return limits
        }
        return recursiveRateLimits(root, depth: 0)
    }

    private static func recursiveRateLimits(_ value: Any, depth: Int) -> [String: Any]? {
        guard depth < 8 else { return nil }
        if let dictionary = value as? [String: Any] {
            if let limits = dictionary["rate_limits"] as? [String: Any] {
                return limits
            }
            for nested in dictionary.values {
                if let found = recursiveRateLimits(nested, depth: depth + 1) {
                    return found
                }
            }
        } else if let array = value as? [Any] {
            for nested in array {
                if let found = recursiveRateLimits(nested, depth: depth + 1) {
                    return found
                }
            }
        }
        return nil
    }

    private static func number(_ value: Any?) -> Double? {
        if let value = value as? Double { return value }
        if let value = value as? Int { return Double(value) }
        if let value = value as? NSNumber { return value.doubleValue }
        if let value = value as? String { return Double(value) }
        return nil
    }

    // MARK: I/O

    public static var sessionsRoot: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appending(path: ".codex/sessions", directoryHint: .isDirectory)
    }

    /// Newest rollout logs first.
    public static func recentRolloutFiles(limit: Int = 5) -> [(url: URL, modified: Date)] {
        let root = sessionsRoot
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        var files: [(url: URL, modified: Date)] = []
        for case let url as URL in enumerator {
            guard url.lastPathComponent.hasPrefix("rollout-"),
                  url.pathExtension == "jsonl" else { continue }
            let values = try? url.resourceValues(forKeys: [.contentModificationDateKey])
            files.append((url, values?.contentModificationDate ?? .distantPast))
        }

        files.sort { $0.modified > $1.modified }
        return Array(files.prefix(limit))
    }

    public static func load(now: Date = Date()) -> ProviderUsage {
        for file in recentRolloutFiles() {
            guard let tail = FileTail.read(url: file.url, maxBytes: 512 * 1024) else { continue }
            for line in tail.split(separator: "\n", omittingEmptySubsequences: true).reversed() {
                if let windows = parse(line: String(line), now: now) {
                    return ProviderUsage(
                        id: .codex,
                        windows: windows,
                        asOf: file.modified,
                        footnote: "Codex のログから取得（古い値の可能性あり）"
                    )
                }
            }
        }

        return ProviderUsage(
            id: .codex,
            error: "rate_limits を含むログが見つかりません。",
            footnote: "Codex のログから取得"
        )
    }

    // MARK: Live endpoint

    private static let usageURL = URL(string: "https://chatgpt.com/backend-api/wham/usage")!

    public static var authFile: URL {
        FileManager.default.homeDirectoryForCurrentUser.appending(path: ".codex/auth.json")
    }

    public struct Credentials: Sendable {
        public let accessToken: String
        public let accountId: String?
        public let expiresAt: Date?
    }

    /// Reads `tokens.access_token` / `tokens.account_id` from `auth.json`. Read-only: the token is
    /// never refreshed or written back, since that would rotate the token Codex itself uses.
    public static func parseCredentials(_ data: Data) -> Credentials? {
        guard
            let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let tokens = root["tokens"] as? [String: Any],
            let token = tokens["access_token"] as? String,
            !token.isEmpty
        else { return nil }
        return Credentials(
            accessToken: token,
            accountId: tokens["account_id"] as? String,
            expiresAt: jwtExpiry(token)
        )
    }

    /// The `exp` claim of a JWT, without verifying it (only used to skip doomed requests).
    static func jwtExpiry(_ token: String) -> Date? {
        let parts = token.split(separator: ".")
        guard parts.count >= 2 else { return nil }
        var payload = parts[1].replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        payload += String(repeating: "=", count: (4 - payload.count % 4) % 4)
        guard
            let data = Data(base64Encoded: payload),
            let claims = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let exp = number(claims["exp"])
        else { return nil }
        return Date(timeIntervalSince1970: exp)
    }

    /// `rate_limit.primary_window` / `secondary_window` of the usage response.
    public static func parse(usageResponse data: Data) -> [UsageWindow]? {
        guard
            let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let limit = root["rate_limit"] as? [String: Any]
        else { return nil }

        var windows: [UsageWindow] = []
        for (key, id) in [("primary_window", "primary"), ("secondary_window", "secondary")] {
            guard
                let entry = limit[key] as? [String: Any],
                let used = number(entry["used_percent"])
            else { continue }
            let minutes = number(entry["limit_window_seconds"]).map { Int($0 / 60) }
            windows.append(
                UsageWindow(
                    id: id,
                    label: DurationText.windowLabel(minutes: minutes),
                    usedPercent: used,
                    resetsAt: number(entry["reset_at"]).map { Date(timeIntervalSince1970: $0) },
                    note: (limit["limit_reached"] as? Bool) == true && used >= 100 ? "上限到達" : nil
                )
            )
        }
        return windows.isEmpty ? nil : windows
    }

    /// Live usage; falls back to the rollout logs when the endpoint cannot be reached.
    public static func fetch() async -> ProviderUsage {
        guard let data = try? Data(contentsOf: authFile), let credentials = parseCredentials(data) else {
            return fallback(reason: "Codex の認証情報が見つかりません")
        }
        if let expiresAt = credentials.expiresAt, expiresAt < Date() {
            return fallback(reason: "トークン期限切れ（Codex を起動すると更新されます）")
        }

        var request = URLRequest(url: usageURL)
        request.timeoutInterval = 15
        request.setValue("Bearer \(credentials.accessToken)", forHTTPHeaderField: "Authorization")
        if let accountId = credentials.accountId {
            request.setValue(accountId, forHTTPHeaderField: "ChatGPT-Account-Id")
        }
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        do {
            let (body, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard (200...299).contains(status) else {
                return fallback(reason: status == 401 ? "Codex で再ログインしてください" : "取得失敗 (HTTP \(status))")
            }
            guard let windows = parse(usageResponse: body) else {
                return fallback(reason: "応答を解釈できませんでした")
            }
            return ProviderUsage(id: .codex, windows: windows, asOf: Date())
        } catch {
            return fallback(reason: "取得失敗（オフライン？）")
        }
    }

    private static func fallback(reason: String) -> ProviderUsage {
        var usage = load()
        usage.footnote = "\(reason)。ログの値を表示中（古い可能性あり）"
        return usage
    }
}
