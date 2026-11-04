import Foundation

/// DSH (DeepSeek Harness) activity from `~/.dsh/sessions/*/session-*/session.v4.jsonl.zstd`.
public enum DSHActivity {
    public static var sessionsRoot: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appending(path: ".dsh/sessions", directoryHint: .isDirectory)
    }

    /// `--Users-foo-my-app--` → `/Users/foo/my-app`.
    /// The encoding turns both `/` and `-` into `-`, so the split is chosen by walking the
    /// directories that actually exist; without a match it falls back to all-slashes.
    public static func cwd(
        fromDirectoryName name: String,
        exists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }
    ) -> String? {
        var trimmed = name
        if trimmed.hasPrefix("--") { trimmed.removeFirst(2) }
        if trimmed.hasSuffix("--") { trimmed.removeLast(2) }
        guard !trimmed.isEmpty else { return nil }

        let parts = trimmed.split(separator: "-", omittingEmptySubsequences: false).map(String.init)
        return resolve(parts[...], under: "", exists: exists)
            ?? "/" + parts.joined(separator: "/")
    }

    private static func resolve(_ parts: ArraySlice<String>, under base: String, exists: (String) -> Bool) -> String? {
        guard let first = parts.indices.first else { return base }
        // Prefer the longest existing component, e.g. `my-app-web` over `my`.
        for end in parts.indices.reversed() {
            let component = parts[first...end].joined(separator: "-")
            guard !component.isEmpty else { continue }
            let path = base + "/" + component
            if exists(path), let full = resolve(parts[(end + 1)...], under: path, exists: exists) {
                return full
            }
        }
        return nil
    }

    /// The last meaningful event, phrased like the other collectors (`bash: npm test`).
    public static func summarize(decompressed: String) -> String {
        // A busy session decompresses to megabytes; only its last events matter.
        let tail = decompressed.utf8.count > 262_144
            ? String(decoding: decompressed.utf8.suffix(262_144), as: UTF8.self)
            : decompressed
        let lines = tail.split(separator: "\n", omittingEmptySubsequences: true).suffix(60)
        for line in lines.reversed() {
            guard
                let data = line.data(using: .utf8),
                let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                let type = object["type"] as? String
            else { continue }
            let payload = object["data"] as? [String: Any] ?? [:]

            switch type {
            case "turn/end":
                return "ターン完了"
            case "tool/call":
                if let name = payload["name"] as? String {
                    return ActivitySummary.summarize(toolName: name, input: arguments(payload["arguments"]))
                }
            case "assistant/message":
                let message = payload["message"] as? [String: Any]
                guard let last = (message?["content"] as? [[String: Any]])?.last else { continue }
                switch last["type"] as? String {
                case "tool-call":
                    if let name = last["name"] as? String {
                        return ActivitySummary.summarize(toolName: name, input: arguments(last["arguments"]))
                    }
                case "text":
                    if let text = last["text"] as? String, !text.isEmpty {
                        return ActivitySummary.truncate(text)
                    }
                case "reasoning", "thinking":
                    return "考え中…"
                default:
                    break
                }
            default:
                // step/*, job/*, tool/result etc. carry no "what" — look further back.
                continue
            }
        }
        return "実行中"
    }

    /// Tool arguments arrive as a JSON string.
    private static func arguments(_ value: Any?) -> [String: Any]? {
        if let object = value as? [String: Any] { return object }
        guard let text = value as? String, let data = text.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    static var zstdPath: String? {
        let candidates = [
            "/opt/homebrew/bin/zstd",
            "/usr/local/bin/zstd",
            "/usr/bin/zstd",
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    public static func collect(within window: TimeInterval = 600, now: Date = Date()) -> [AgentSession] {
        let root = sessionsRoot
        guard let projects = try? FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        let keys: Set<URLResourceKey> = [.contentModificationDateKey, .fileSizeKey]
        var sessions: [AgentSession] = []

        for project in projects {
            guard let sessionDirs = try? FileManager.default.contentsOfDirectory(
                at: project,
                includingPropertiesForKeys: Array(keys),
                options: [.skipsHiddenFiles]
            ) else { continue }

            for sessionDir in sessionDirs {
                let file = sessionDir.appending(path: "session.v4.jsonl.zstd")
                guard let values = try? file.resourceValues(forKeys: keys),
                      let modified = values.contentModificationDate,
                      now.timeIntervalSince(modified) <= window
                else { continue }

                let stamp = "\(modified.timeIntervalSince1970)-\(values.fileSize ?? 0)"
                sessions.append(
                    AgentSession(
                        id: "dsh:\(file.path)",
                        tool: .dsh,
                        cwd: cwd(fromDirectoryName: project.lastPathComponent),
                        lastUpdate: modified,
                        summary: cachedSummary(url: file, stamp: stamp)
                    )
                )
            }
        }
        return sessions
    }

    /// Decompressing a session log is expensive, so only redo it when the file changed.
    private static func cachedSummary(url: URL, stamp: String) -> String {
        if let cached = summaryCache.value(for: url.path, stamp: stamp) {
            return cached
        }
        let summary = summarize(url: url)
        summaryCache.store(summary, for: url.path, stamp: stamp)
        return summary
    }

    private static let summaryCache = DSHSummaryCache()


    static func summarize(url: URL) -> String {
        guard let zstd = zstdPath else { return "実行中" }
        let result = Shell.run(zstd, ["-dc", url.path], timeout: 5)
        guard !result.stdout.isEmpty else { return "実行中" }
        return summarize(decompressed: result.stdout)
    }
}

/// path → (file stamp, summary) memo so unchanged sessions are not decompressed again.
private final class DSHSummaryCache: @unchecked Sendable {
    private struct Entry {
        let stamp: String
        let summary: String
    }

    private let lock = NSLock()
    private var entries: [String: Entry] = [:]

    func value(for path: String, stamp: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        guard let entry = entries[path], entry.stamp == stamp else { return nil }
        return entry.summary
    }

    func store(_ summary: String, for path: String, stamp: String) {
        lock.lock()
        entries[path] = Entry(stamp: stamp, summary: summary)
        lock.unlock()
    }
}
