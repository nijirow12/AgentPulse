import Foundation

/// OpenCode activity from the local SQLite DB.
public enum OpenCodeActivity {
    /// Summary of the last content element of one assistant message.
    public static func summarize(dataJSON: String, type: String? = nil) -> String {
        guard
            let data = dataJSON.data(using: .utf8),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return "実行中" }

        if let content = object["content"] as? [Any], let last = content.last as? [String: Any] {
            switch last["type"] as? String {
            case "tool":
                let name = (last["name"] as? String) ?? "tool"
                let input = (last["state"] as? [String: Any])?["input"] as? [String: Any]
                return ActivitySummary.summarize(toolName: name, input: input)
            case "text":
                let text = ActivitySummary.truncate(last["text"] as? String ?? "")
                return text.isEmpty ? "考え中…" : text
            case "reasoning":
                let text = ActivitySummary.truncate(last["text"] as? String ?? "")
                return text.isEmpty ? "考え中…" : text
            default:
                break
            }
        }

        if let text = object["text"] as? String {
            let trimmed = ActivitySummary.truncate(text)
            if !trimmed.isEmpty { return trimmed }
        }
        return type == "user" ? "入力待ち" : "考え中…"
    }

    public static func collect(
        within window: TimeInterval = 600,
        databasePath: String = OpenCodeGoUsage.defaultDatabasePath,
        now: Date = Date()
    ) -> [AgentSession] {
        guard let db = SQLiteReader(path: databasePath) else { return [] }

        let since = Int64((now.timeIntervalSince1970 - window) * 1_000)
        guard let rows = db.query(
            """
            SELECT session_id, time_created, data, type
            FROM session_message
            WHERE time_created > ?
            ORDER BY time_created DESC
            """,
            [.integer(since)]
        ) else { return [] }

        // Latest row per session, preferring assistant messages.
        var chosen: [String: SQLiteRow] = [:]
        for row in rows {
            guard let sessionId = row["session_id"]?.stringValue else { continue }
            let existing = chosen[sessionId]
            if existing == nil {
                chosen[sessionId] = row
            } else if existing?["type"]?.stringValue != "assistant",
                      row["type"]?.stringValue == "assistant" {
                chosen[sessionId] = row
            }
        }

        let directories = sessionDirectories(db: db, ids: Array(chosen.keys))

        return chosen.compactMap { sessionId, row -> AgentSession? in
            guard let milliseconds = row["time_created"]?.doubleValue else { return nil }
            let updated = Date(timeIntervalSince1970: milliseconds / 1_000)
            let summary = summarize(
                dataJSON: row["data"]?.stringValue ?? "",
                type: row["type"]?.stringValue
            )
            return AgentSession(
                id: "opencode:\(sessionId)",
                tool: .opencode,
                cwd: directories[sessionId],
                lastUpdate: updated,
                summary: summary
            )
        }
    }

    static func sessionDirectories(db: SQLiteReader, ids: [String]) -> [String: String] {
        guard !ids.isEmpty else { return [:] }
        let placeholders = ids.map { _ in "?" }.joined(separator: ", ")
        guard let rows = db.query(
            "SELECT id, directory FROM session_v2 WHERE id IN (\(placeholders))",
            ids.map { SQLiteValue.text($0) }
        ) else { return [:] }

        var directories: [String: String] = [:]
        for row in rows {
            if let id = row["id"]?.stringValue, let directory = row["directory"]?.stringValue {
                directories[id] = directory
            }
        }
        return directories
    }
}
