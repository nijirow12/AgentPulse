import Foundation

public struct ProcInfo: Sendable, Identifiable, Equatable {
    public var pid: Int32
    public var cpu: Double
    public var command: String
    public var tool: AgentTool
    public var cwd: String?

    public var id: Int32 { pid }

    public init(pid: Int32, cpu: Double, command: String, tool: AgentTool, cwd: String? = nil) {
        self.pid = pid
        self.cpu = cpu
        self.command = command
        self.tool = tool
        self.cwd = cwd
    }
}

/// Finds running agent CLIs (`ps`) and their working directory (`lsof`).
public enum ProcessScanner {
    /// Parses `/bin/ps -axo pid=,pcpu=,etime=,command=` output.
    public static func parsePS(_ output: String, excluding: Set<Int32> = []) -> [ProcInfo] {
        var found: [ProcInfo] = []
        for line in output.split(separator: "\n", omittingEmptySubsequences: true) {
            let parts = line.split(separator: " ", maxSplits: 3, omittingEmptySubsequences: true)
            guard parts.count >= 4,
                  let pid = Int32(parts[0]),
                  let cpu = Double(parts[1])
            else { continue }
            guard !excluding.contains(pid) else { continue }

            let command = String(parts[3])
            guard let tool = classify(command: command) else { continue }

            found.append(ProcInfo(pid: pid, cpu: cpu, command: command, tool: tool))
        }
        return found
    }

    /// Detects which agent CLI a command line belongs to.
    /// The executable path may contain spaces (`~/Library/Application Support/...`),
    /// so the binary is found by its last path component rather than the first word.
    public static func classify(command: String) -> AgentTool? {
        let trimmed = command.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        if helperFlags.contains(where: trimmed.contains) { return nil }
        if trimmed.contains("dsh/lib/bin.js") { return .dsh }

        guard let match = trimmed.firstMatch(of: agentBinary) else { return nil }
        switch match.1 {
        case "claude": return .claude
        case "codex": return .codex
        case "opencode": return .opencode
        default: return nil
        }
    }

    /// `claude`, `claude-code`, `claude.exe`, `codex`, `opencode` as a whole path component.
    nonisolated(unsafe) private static let agentBinary =
        /(?:^|\/)(claude|codex|opencode)(?:-[a-z]+)?(?:\.exe)?(?:\s|$)/

    /// Wrappers and long-lived helpers that mention an agent binary but never run an agent turn
    /// themselves (Claude.app's `disclaimer` wrapper, the browser bridge, opencode's background service).
    private static let helperFlags = ["--chrome-native-host", "/Helpers/disclaimer ", " serve --service"]

    /// Where a log-less process lives, shown in place of an activity summary.
    public static func hostHint(command: String) -> String? {
        if command.contains("/.cursor/extensions/") { return "Cursor 拡張" }
        if command.contains("/.vscode/extensions/") { return "VS Code 拡張" }
        if command.contains("ChatGPT.app") { return "ChatGPT アプリ" }
        if command.contains("Application Support/Claude/") { return "Claude アプリ" }
        if command.contains(" app-server") { return "app-server" }
        return nil
    }

    /// Reads `lsof -a -d cwd -p <pid> -Fn` output.
    public static func parseLsofCWD(_ output: String) -> String? {
        for line in output.split(separator: "\n") where line.hasPrefix("n") {
            let path = String(line.dropFirst())
            if !path.isEmpty { return path }
        }
        return nil
    }

    /// `ps` alone costs ~40ms of CPU, so a scan is reused for `maxAge` seconds;
    /// agent processes start and stop far less often than their logs change.
    public static func scan(maxAge: TimeInterval = 15, now: Date = Date()) -> [ProcInfo] {
        if let cached = scanCache.value(maxAge: maxAge, now: now) { return cached }
        let processes = scanNow()
        scanCache.store(processes, at: now)
        return processes
    }

    private static let scanCache = ScanCache()

    private static func scanNow() -> [ProcInfo] {
        let result = Shell.run("/bin/ps", ["-axo", "pid=,pcpu=,etime=,command="], timeout: 5)
        guard result.succeeded || !result.stdout.isEmpty else { return [] }

        let ourPid = Int32(ProcessInfo.processInfo.processIdentifier)
        var processes = parsePS(result.stdout, excluding: [ourPid])

        // A CLI's cwd never changes, so `lsof` only has to run once per pid.
        cwdCache.retain(only: Set(processes.map(\.pid)))

        for index in processes.indices {
            let pid = processes[index].pid
            if let cached = cwdCache.value(for: pid) {
                processes[index].cwd = cached
                continue
            }
            let lsof = Shell.run(
                "/usr/sbin/lsof",
                ["-a", "-d", "cwd", "-p", String(pid), "-Fn"],
                timeout: 3
            )
            let cwd = lsof.succeeded ? parseLsofCWD(lsof.stdout) : nil
            processes[index].cwd = cwd
            // Remember failures too, or an unreadable pid costs an lsof run every refresh.
            cwdCache.store(cwd, for: pid)
        }
        return processes
    }

    private static let cwdCache = CWDCache()
}

/// pid → cwd memo. Bounded by the currently running agent processes.
private final class CWDCache: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Int32: String?] = [:]

    /// `.some(nil)` means lsof already failed for this pid.
    func value(for pid: Int32) -> String?? {
        lock.lock()
        defer { lock.unlock() }
        return values[pid]
    }

    func store(_ cwd: String?, for pid: Int32) {
        lock.lock()
        values[pid] = .some(cwd)
        lock.unlock()
    }

    func retain(only pids: Set<Int32>) {
        lock.lock()
        values = values.filter { pids.contains($0.key) }
        lock.unlock()
    }
}

private final class ScanCache: @unchecked Sendable {
    private let lock = NSLock()
    private var processes: [ProcInfo] = []
    private var takenAt: Date?

    func value(maxAge: TimeInterval, now: Date) -> [ProcInfo]? {
        lock.lock()
        defer { lock.unlock() }
        guard let takenAt, now.timeIntervalSince(takenAt) < maxAge else { return nil }
        return processes
    }

    func store(_ processes: [ProcInfo], at date: Date) {
        lock.lock()
        self.processes = processes
        takenAt = date
        lock.unlock()
    }
}
