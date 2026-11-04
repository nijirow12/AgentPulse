import Foundation

/// Merges every activity source and binds log-only entries to live processes.
public enum ActivityAggregator {
    /// Full collection (blocking I/O) — call from a background task.
    public static func collect(within window: TimeInterval = 600, now: Date = Date()) -> [AgentSession] {
        let processes = ProcessScanner.scan()
        let sessions =
            ClaudeActivity.collect(within: window, now: now)
            + CodexActivity.collect(within: window, now: now)
            + OpenCodeActivity.collect(within: window, now: now)
            + DSHActivity.collect(within: window, now: now)

        return merge(sessions: sessions, processes: processes, within: window, now: now)
    }

    /// Pure merge step (no I/O), used by the app and tests.
    public static func merge(
        sessions: [AgentSession],
        processes: [ProcInfo],
        within window: TimeInterval = 600,
        now: Date = Date()
    ) -> [AgentSession] {
        let available = processes
        var used = Set<Int32>()
        var merged: [AgentSession] = []

        for var session in sessions {
            if let index = matchIndex(for: session, in: available, used: used) {
                let process = available[index]
                session.pid = process.pid
                session.cpu = process.cpu
                if session.cwd == nil { session.cwd = process.cwd }
                used.insert(process.pid)
            }
            merged.append(session)
        }

        // Processes with no matching log still deserve a row.
        for process in available where !used.contains(process.pid) {
            let state = process.cpu >= 1 ? "実行中" : "待機中"
            let hint = ProcessScanner.hostHint(command: process.command)
            merged.append(
                AgentSession(
                    id: "process:\(process.pid)",
                    tool: process.tool,
                    cwd: process.cwd == "/" ? nil : process.cwd,
                    lastUpdate: now,
                    summary: [state, hint].compactMap { $0 }.joined(separator: " · "),
                    pid: process.pid,
                    cpu: process.cpu,
                    isProcessOnly: true
                )
            )
        }

        // Sessions with a log first (newest first), then the bare processes.
        return merged
            .filter { now.timeIntervalSince($0.lastUpdate) <= window }
            .sorted { lhs, rhs in
                if lhs.isProcessOnly != rhs.isProcessOnly { return !lhs.isProcessOnly }
                if lhs.isProcessOnly { return (lhs.cpu ?? 0) > (rhs.cpu ?? 0) }
                return lhs.lastUpdate > rhs.lastUpdate
            }
    }

    private static func matchIndex(
        for session: AgentSession,
        in processes: [ProcInfo],
        used: Set<Int32>
    ) -> Int? {
        let candidates = processes.indices.filter {
            !used.contains(processes[$0].pid) && processes[$0].tool == session.tool
        }
        guard !candidates.isEmpty else { return nil }

        if let cwd = session.cwd {
            let normalized = normalize(cwd)
            if let exact = candidates.first(where: {
                processes[$0].cwd.map(normalize) == normalized
            }) {
                return exact
            }
            // The agent may have `cd`-ed into a subdirectory of where it was started.
            let nested = candidates
                .compactMap { index -> (Int, Int)? in
                    guard let root = processes[index].cwd.map(normalize), root != "/",
                          normalized.hasPrefix(root + "/")
                    else { return nil }
                    return (index, root.count)
                }
                .max { $0.1 < $1.1 }
            if let nested { return nested.0 }
        }
        if candidates.count == 1 {
            return candidates[0]
        }
        return nil
    }

    private static func normalize(_ path: String) -> String {
        var value = path
        if value.hasSuffix("/") { value.removeLast() }
        return (value as NSString).resolvingSymlinksInPath
    }
}
