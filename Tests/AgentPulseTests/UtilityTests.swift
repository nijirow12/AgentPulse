import XCTest
@testable import AgentPulseCore

final class ShellTests: XCTestCase {
    func testCapturesStdoutAndStatus() {
        let result = Shell.run("/bin/echo", ["hello"], timeout: 5)
        XCTAssertTrue(result.succeeded)
        XCTAssertEqual(result.stdout.trimmingCharacters(in: .whitespacesAndNewlines), "hello")
    }

    func testMissingExecutableReturnsPromptly() {
        let start = Date()
        let result = Shell.run("/nonexistent/agentpulse-binary", [], timeout: 2)
        XCTAssertFalse(result.succeeded)
        XCTAssertLessThan(Date().timeIntervalSince(start), 2, "must not block on unopened pipes")
    }

    func testTimeoutTerminates() {
        let start = Date()
        let result = Shell.run("/bin/sleep", ["10"], timeout: 0.3)
        XCTAssertFalse(result.succeeded)
        XCTAssertLessThan(Date().timeIntervalSince(start), 3)
    }
}

final class FileTailTests: XCTestCase {
    func testReturnsWholeSmallFile() throws {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "agentpulse-tail-\(UUID().uuidString).txt")
        try "line1\nline2\n".write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }

        XCTAssertEqual(FileTail.read(url: url, maxBytes: 1024), "line1\nline2\n")
    }

    func testDropsPartialFirstLine() throws {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "agentpulse-tail-\(UUID().uuidString).txt")
        try "aaaa\nbbbb\ncccc\n".write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }

        XCTAssertEqual(FileTail.read(url: url, maxBytes: 7), "cccc\n")
    }

    func testMissingFileReturnsNil() {
        let url = URL(fileURLWithPath: "/tmp/agentpulse-does-not-exist-\(UUID().uuidString)")
        XCTAssertNil(FileTail.read(url: url))
    }
}

final class SQLiteReaderTests: XCTestCase {
    func testReadOnlyQueryOfSystemDatabase() throws {
        // Create a database with sqlite3 CLI so we do not need a writer module.
        let path = FileManager.default.temporaryDirectory
            .appending(path: "agentpulse-\(UUID().uuidString).db").path
        defer { try? FileManager.default.removeItem(atPath: path) }

        let create = Shell.run("/usr/bin/sqlite3", [path, "CREATE TABLE t(a TEXT, b INTEGER); INSERT INTO t VALUES('x', 42);"])
        try XCTSkipUnless(create.succeeded, "sqlite3 CLI unavailable")

        let reader = try XCTUnwrap(SQLiteReader(path: path))
        let rows = reader.query("SELECT a, b FROM t")
        XCTAssertEqual(rows?.count, 1)
        XCTAssertEqual(rows?.first?["a"]?.stringValue, "x")
        XCTAssertEqual(rows?.first?["b"]?.intValue, 42)

        // Read-only: writes must fail.
        XCTAssertNil(reader.query("INSERT INTO t VALUES('y', 1)"))
    }
}
