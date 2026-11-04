import XCTest
@testable import AgentPulseCore

final class ProcessScannerTests: XCTestCase {
    private let psOutput = """
      123  0.0 01:23:45 /usr/local/bin/claude --resume
      456  1.5 00:00:12 node /Users/me/.dsh/lib/bin.js run
      789  0.1 10:00 opencode
      999  0.0 01:00 /usr/bin/grep claude
     1000  0.0 01:00 /Applications/AgentPulse.app/Contents/MacOS/AgentPulse
    """

    func testParsesAndClassifies() {
        let processes = ProcessScanner.parsePS(psOutput, excluding: [1000])
        XCTAssertEqual(processes.count, 3)

        XCTAssertEqual(processes[0].pid, 123)
        XCTAssertEqual(processes[0].tool, .claude)
        XCTAssertEqual(processes[0].cpu, 0.0, accuracy: 0.001)

        XCTAssertEqual(processes[1].tool, .dsh)
        XCTAssertEqual(processes[2].tool, .opencode)
    }

    func testClassify() {
        XCTAssertEqual(ProcessScanner.classify(command: "/opt/homebrew/bin/claude"), .claude)
        XCTAssertEqual(ProcessScanner.classify(command: "claude-code --print"), .claude)
        XCTAssertEqual(ProcessScanner.classify(command: "codex exec"), .codex)
        XCTAssertEqual(ProcessScanner.classify(command: "opencode run"), .opencode)
        XCTAssertEqual(ProcessScanner.classify(command: "node /x/dsh/lib/bin.js"), .dsh)
        XCTAssertNil(ProcessScanner.classify(command: "grep claude"))
        XCTAssertNil(ProcessScanner.classify(command: "vim"))
    }

    func testParseLsof() {
        let output = """
        p123
        fcwd
        n/Users/me/proj
        """
        XCTAssertEqual(ProcessScanner.parseLsofCWD(output), "/Users/me/proj")
        XCTAssertNil(ProcessScanner.parseLsofCWD("p123\nfcwd\n"))
    }
}

final class ActivityAggregatorTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_793_404_800)

    func testBindsLogsToProcessesAndKeepsOrphans() {
        let sessions = [
            AgentSession(
                id: "claude:a",
                tool: .claude,
                cwd: "/Users/me/proj",
                lastUpdate: now.addingTimeInterval(-10),
                summary: "Bash: npm test"
            ),
            AgentSession(
                id: "opencode:old",
                tool: .opencode,
                cwd: "/Users/me/old",
                lastUpdate: now.addingTimeInterval(-3_600),
                summary: "考え中…"
            ),
        ]
        let processes = [
            ProcInfo(pid: 42, cpu: 3.5, command: "claude", tool: .claude, cwd: "/Users/me/proj"),
            ProcInfo(pid: 43, cpu: 0.2, command: "codex", tool: .codex, cwd: "/Users/me/codex"),
        ]

        let merged = ActivityAggregator.merge(
            sessions: sessions,
            processes: processes,
            within: 600,
            now: now
        )

        XCTAssertEqual(merged.count, 2, "stale log is dropped, orphan process is kept")

        let logRow = try? XCTUnwrap(merged.first { $0.id == "claude:a" })
        XCTAssertEqual(logRow?.pid, 42)
        XCTAssertEqual(logRow?.cpu ?? 0, 3.5, accuracy: 0.001)

        let processRow = try? XCTUnwrap(merged.first { $0.id == "process:43" })
        XCTAssertTrue(processRow?.summary.hasPrefix("実行中") == true || processRow?.summary.hasPrefix("待機中") == true)
        XCTAssertEqual(processRow?.cwd, "/Users/me/codex")
        XCTAssertEqual(merged.first?.id, "claude:a", "rows with a log come before bare processes")
    }

    func testSingleProcessOfToolMatchesEvenWithoutCWD() {
        let session = AgentSession(
            id: "codex:a",
            tool: .codex,
            cwd: nil,
            lastUpdate: now,
            summary: "shell: ls"
        )
        let processes = [ProcInfo(pid: 7, cpu: 1, command: "codex", tool: .codex, cwd: "/Users/me/x")]

        let merged = ActivityAggregator.merge(
            sessions: [session],
            processes: processes,
            within: 600,
            now: now
        )
        XCTAssertEqual(merged.count, 1)
        XCTAssertEqual(merged[0].pid, 7)
        XCTAssertEqual(merged[0].cwd, "/Users/me/x")
    }
}

final class DurationTextTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_793_404_800)

    func testRemaining() {
        XCTAssertEqual(DurationText.remaining(until: now.addingTimeInterval(2 * 3_600 + 13 * 60), now: now), "2h 13m")
        XCTAssertEqual(DurationText.remaining(until: now.addingTimeInterval(45 * 60), now: now), "45m")
        XCTAssertEqual(DurationText.remaining(until: now.addingTimeInterval(-5), now: now), "0m")
        XCTAssertEqual(DurationText.remaining(until: now.addingTimeInterval(3 * 86_400 + 4 * 3_600), now: now), "3d 4h")
    }

    func testElapsed() {
        XCTAssertEqual(DurationText.elapsed(since: now.addingTimeInterval(-12), now: now), "12s ago")
        XCTAssertEqual(DurationText.elapsed(since: now.addingTimeInterval(-5 * 60), now: now), "5m ago")
        XCTAssertEqual(DurationText.elapsed(since: now.addingTimeInterval(-3 * 3_600), now: now), "3h ago")
        XCTAssertEqual(DurationText.elapsed(since: now.addingTimeInterval(-2 * 86_400), now: now), "2d ago")
    }
}

final class PreferencesTests: XCTestCase {
    func testDefaultsFallBackWhenUnset() throws {
        let suite = try XCTUnwrap(UserDefaults(suiteName: "AgentPulseTests-\(UUID().uuidString)"))
        let preferences = Preferences.load(from: suite)
        XCTAssertEqual(preferences.openCodeLimits.fiveHourUSD, 12, accuracy: 0.001)
        XCTAssertEqual(preferences.openCodeLimits.weeklyUSD, 30, accuracy: 0.001)
        XCTAssertEqual(preferences.openCodeLimits.monthlyUSD, 60, accuracy: 0.001)
        XCTAssertEqual(preferences.activityWindow, 600, accuracy: 0.001)
    }

    func testVisibilityTogglesAreRespected() throws {
        let suite = try XCTUnwrap(UserDefaults(suiteName: "AgentPulseTests-\(UUID().uuidString)"))
        suite.set(false, forKey: SettingsKey.showClaude)
        suite.set(true, forKey: SettingsKey.showCodex)
        let preferences = Preferences.load(from: suite)
        XCTAssertFalse(preferences.visibleProviders.contains(.claude))
        XCTAssertTrue(preferences.visibleProviders.contains(.codex))
    }
}

final class ProcessClassifyReviewTests: XCTestCase {
    func testDetectsBinariesUnderPathsWithSpaces() {
        XCTAssertEqual(ProcessScanner.classify(command: "/Users/x/Library/Application Support/Claude/claude-code/2.1.309/abc/claude.app/Contents/MacOS/claude --output-format stream-json"), .claude)
        XCTAssertEqual(ProcessScanner.classify(command: "/Applications/ChatGPT.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex app-server"), .codex)
    }

    func testIgnoresHelpersAndLookalikes() {
        XCTAssertNil(ProcessScanner.classify(command: "/usr/lib/node_modules/@anthropic-ai/claude-code/bin/claude.exe --chrome-native-host"))
        XCTAssertNil(ProcessScanner.classify(command: "/bin/zsh -c source /Users/x/.claude/shell-snapshots/snap.sh"))
        XCTAssertNil(ProcessScanner.classify(command: "/Applications/Claude.app/Contents/MacOS/Claude"))
    }

    func testIdleProcessOnlyRowsSortLastAndAreIdle() {
        let now = Date()
        let log = AgentSession(id: "a", tool: .claude, cwd: "/p", lastUpdate: now.addingTimeInterval(-60), summary: "Bash: ls")
        let procs = [ProcInfo(pid: 9, cpu: 0.1, command: "/Users/x/.cursor/extensions/a/codex app-server", tool: .codex, cwd: "/")]
        let merged = ActivityAggregator.merge(sessions: [log], processes: procs, now: now)
        XCTAssertEqual(merged.map(\.id), ["a", "process:9"])
        XCTAssertTrue(merged[1].isIdleProcess)
        XCTAssertNil(merged[1].cwd)
        XCTAssertEqual(merged[1].summary, "待機中 · Cursor 拡張")
    }

    func testLogBindsToProcessStartedInParentDirectory() {
        let now = Date()
        let log = AgentSession(id: "a", tool: .claude, cwd: "/w/app/sub", lastUpdate: now, summary: "Edit: x")
        let procs = [
            ProcInfo(pid: 1, cpu: 0, command: "claude", tool: .claude, cwd: "/w"),
            ProcInfo(pid: 2, cpu: 5, command: "claude", tool: .claude, cwd: "/w/app"),
        ]
        let merged = ActivityAggregator.merge(sessions: [log], processes: procs, now: now)
        XCTAssertEqual(merged.first?.pid, 2)
    }

    func testIgnoresWrappersAndServices() {
        XCTAssertNil(ProcessScanner.classify(command: "/Applications/Claude.app/Contents/Helpers/disclaimer --pgroup -- /Users/x/Library/Application Support/Claude/claude-code/2/claude.app/Contents/MacOS/claude --output-format stream-json"))
        XCTAssertNil(ProcessScanner.classify(command: "/Users/x/lib/node_modules/@opencode/cli/bin/opencode.exe serve --service"))
    }
}

final class WorkingSessionTests: XCTestCase {
    func testWorkingMeansRecentLogOrBusyProcess() {
        let now = Date()
        let fresh = AgentSession(id: "a", tool: .claude, lastUpdate: now.addingTimeInterval(-10), summary: "")
        let quiet = AgentSession(id: "b", tool: .claude, lastUpdate: now.addingTimeInterval(-120), summary: "")
        let quietButBusy = AgentSession(id: "c", tool: .codex, lastUpdate: now.addingTimeInterval(-120), summary: "", pid: 1, cpu: 40)
        let idleHelper = AgentSession(id: "d", tool: .codex, lastUpdate: now, summary: "", pid: 2, cpu: 0.2, isProcessOnly: true)
        XCTAssertTrue(fresh.isWorking(now: now))
        XCTAssertFalse(quiet.isWorking(now: now))
        XCTAssertTrue(quietButBusy.isWorking(now: now))
        XCTAssertFalse(idleHelper.isWorking(now: now))
    }
}
