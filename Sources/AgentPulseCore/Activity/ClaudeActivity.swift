import Foundation

/// Claude Code activity from `~/.claude/projects/*/*.jsonl`.
public struct ClaudeActivitySummary: Sendable, Equatable {
    public var cwd: String?
    public var summary: String
    public var timestamp: Date?

    public init(cwd: String?, summary: String, timestamp: Date? = nil) {
        self.cwd = cwd
        self.summary = summary
        self.timestamp = timestamp
    }
}

public enum ClaudeActivity {
    /// Summarizes the last assistant entry in a JSONL tail.
    public static func summarize(tail: String) -> ClaudeActivitySummary? {
        for line in tail.split(separator: "\n", omittingEmptySubsequences: true).reversed() {
            guard line.contains("\"assistant\"") else { continue }
            guard
                let data = line.data(using: .utf8),
                let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                object["type"] as? String == "assistant"
            else { continue }

            let cwd = object["cwd"] as? String
            let timestamp = ISO8601.parse(object["timestamp"] as? String)
            let summary = summarize(message: object["message"])
            return ClaudeActivitySummary(cwd: cwd, summary: summary, timestamp: timestamp)
        }
        return nil
    }

    /// `message.content[]`'s last element → "Bash: npm test" / text head / 考え中…
    static func summarize(message: Any?) -> String {
        guard let message = message as? [String: Any] else { return "考え中…" }
        if let content = message["content"] as? [Any], let last = content.last as? [String: Any] {
            switch last["type"] as? String {
            case "tool_use":
                let name = last["name"] as? String ?? "tool"
                return ActivitySummary.summarize(toolName: name, input: last["input"] as? [String: Any])
            case "text":
                let text = ActivitySummary.truncate(last["text"] as? String ?? "")
                return text.isEmpty ? "考え中…" : text
            case "thinking":
                return "考え中…"
            default:
                break
            }
        }
        if let content = message["content"] as? String {
            let text = ActivitySummary.truncate(content)
            return text.isEmpty ? "考え中…" : text
        }
        return "考え中…"
    }

    public static var projectsRoot: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appending(path: ".claude/projects", directoryHint: .isDirectory)
    }

    public static func collect(within window: TimeInterval = 600, now: Date = Date()) -> [AgentSession] {
        let root = projectsRoot
        let keys: [URLResourceKey] = [.contentModificationDateKey, .isRegularFileKey]
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles]
        ) else { return [] }

        var sessions: [AgentSession] = []
        for case let url as URL in enumerator {
            guard url.pathExtension == "jsonl" else { continue }
            guard let values = try? url.resourceValues(forKeys: Set(keys)),
                  let modified = values.contentModificationDate,
                  now.timeIntervalSince(modified) <= window
            else { continue }

            guard let tail = FileTail.read(url: url, maxBytes: 64 * 1024),
                  let summary = summarize(tail: tail)
            else { continue }

            sessions.append(
                AgentSession(
                    id: "claude:\(url.deletingPathExtension().lastPathComponent)",
                    tool: .claude,
                    cwd: summary.cwd,
                    lastUpdate: modified,
                    summary: summary.summary
                )
            )
        }
        return sessions
    }
}
