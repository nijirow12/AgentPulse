import Foundation

public struct CodexActivitySummary: Sendable, Equatable {
    public var cwd: String?
    public var summary: String
}

/// Codex CLI activity from `~/.codex/sessions/**.jsonl`.
public enum CodexActivity {
    /// Looks at the tail for the last meaningful event (function call, message, reasoning).
    public static func summarize(tail: String) -> CodexActivitySummary? {
        for line in tail.split(separator: "\n", omittingEmptySubsequences: true).reversed() {
            guard
                let data = line.data(using: .utf8),
                let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                let payload = object["payload"] as? [String: Any],
                let type = payload["type"] as? String
            else { continue }

            switch type {
            case "function_call":
                let name = payload["name"] as? String ?? "tool"
                let summary = summarizeCall(name: name, arguments: payload["arguments"])
                return CodexActivitySummary(cwd: payload["cwd"] as? String, summary: summary)

            case "local_shell_call":
                let action = payload["action"] as? [String: Any]
                let command = ActivitySummary.stringValue(action?["command"]) ?? ""
                let summary = command.isEmpty ? "shell" : "shell: \(ActivitySummary.truncate(command))"
                return CodexActivitySummary(cwd: payload["cwd"] as? String, summary: summary)

            case "agent_message":
                let text = ActivitySummary.truncate(payload["message"] as? String ?? "")
                guard !text.isEmpty else { continue }
                return CodexActivitySummary(cwd: payload["cwd"] as? String, summary: text)

            case "reasoning":
                let text = reasoningText(payload)
                return CodexActivitySummary(cwd: payload["cwd"] as? String, summary: text)

            default:
                continue
            }
        }
        return nil
    }

    /// `arguments` is normally a JSON *string*; fall back to the raw head.
    static func summarizeCall(name: String, arguments: Any?) -> String {
        if let string = arguments as? String {
            if let data = string.data(using: .utf8),
               let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                return ActivitySummary.summarize(toolName: name, input: object)
            }
            let trimmed = ActivitySummary.truncate(string)
            return trimmed.isEmpty ? name : "\(name): \(trimmed)"
        }
        if let object = arguments as? [String: Any] {
            return ActivitySummary.summarize(toolName: name, input: object)
        }
        return name
    }

    private static func reasoningText(_ payload: [String: Any]) -> String {
        if let summary = payload["summary"] as? [Any] {
            for entry in summary {
                if let dictionary = entry as? [String: Any],
                   let text = dictionary["text"] as? String,
                   !text.isEmpty {
                    return ActivitySummary.truncate(text)
                }
            }
        }
        if let content = payload["content"] as? [Any] {
            for entry in content {
                if let dictionary = entry as? [String: Any],
                   let text = dictionary["text"] as? String,
                   !text.isEmpty {
                    return ActivitySummary.truncate(text)
                }
            }
        }
        return "考え中…"
    }

    /// Reads `payload.cwd` from `session_meta` / `turn_context` in the head of the file.
    public static func cwd(head: String) -> String? {
        for line in head.split(separator: "\n", omittingEmptySubsequences: true) {
            guard line.contains("\"cwd\"") else { continue }
            guard
                let data = line.data(using: .utf8),
                let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                let payload = object["payload"] as? [String: Any],
                let cwd = payload["cwd"] as? String
            else { continue }
            return cwd
        }
        return nil
    }

    public static func collect(within window: TimeInterval = 600, now: Date = Date()) -> [AgentSession] {
        var sessions: [AgentSession] = []
        for file in CodexUsage.recentRolloutFiles(limit: 20) {
            guard now.timeIntervalSince(file.modified) <= window else { continue }
            guard let tail = FileTail.read(url: file.url, maxBytes: 128 * 1024) else { continue }

            let summary = summarize(tail: tail)
            let workingDirectory = summary?.cwd ?? headCWD(url: file.url)
            sessions.append(
                AgentSession(
                    id: "codex:\(file.url.lastPathComponent)",
                    tool: .codex,
                    cwd: workingDirectory,
                    lastUpdate: file.modified,
                    summary: summary?.summary ?? "実行中"
                )
            )
        }
        return sessions
    }

    private static func headCWD(url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        let data = (try? handle.read(upToCount: 16 * 1024)) ?? Data()
        return cwd(head: String(decoding: data, as: UTF8.self))
    }
}
