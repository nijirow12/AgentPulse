import XCTest
@testable import AgentPulseCore

final class ClaudeActivityTests: XCTestCase {
    private let tail = #"""
    {"type":"user","cwd":"/Users/me/proj","message":{"role":"user","content":"run the tests"}}
    {"type":"assistant","cwd":"/Users/me/proj","message":{"role":"assistant","content":[{"type":"text","text":"Let me run it."},{"type":"tool_use","name":"Bash","input":{"command":"npm test"}}]}}
    """#

    func testSummarizesLastToolUse() throws {
        let summary = try XCTUnwrap(ClaudeActivity.summarize(tail: tail))
        XCTAssertEqual(summary.summary, "Bash: npm test")
        XCTAssertEqual(summary.cwd, "/Users/me/proj")
    }

    func testSummarizesTextAndThinking() throws {
        let textTail = #"""
        {"type":"assistant","cwd":"/tmp","message":{"content":[{"type":"text","text":"実装を確認しています"}]}}
        """#
        let text = try XCTUnwrap(ClaudeActivity.summarize(tail: textTail))
        XCTAssertEqual(text.summary, "実装を確認しています")

        let thinkingTail = #"""
        {"type":"assistant","cwd":"/tmp","message":{"content":[{"type":"thinking","thinking":"..."}]}}
        """#
        let thinking = try XCTUnwrap(ClaudeActivity.summarize(tail: thinkingTail))
        XCTAssertEqual(thinking.summary, "考え中…")
    }

    func testPrefersFilePathAndPattern() throws {
        let edit = #"""
        {"type":"assistant","cwd":"/tmp","message":{"content":[{"type":"tool_use","name":"Edit","input":{"file_path":"src/App.tsx"}}]}}
        """#
        XCTAssertEqual(try XCTUnwrap(ClaudeActivity.summarize(tail: edit)).summary, "Edit: src/App.tsx")

        let grep = #"""
        {"type":"assistant","cwd":"/tmp","message":{"content":[{"type":"tool_use","name":"Grep","input":{"pattern":"TODO"}}]}}
        """#
        XCTAssertEqual(try XCTUnwrap(ClaudeActivity.summarize(tail: grep)).summary, "Grep: TODO")
    }

    func testBrokenLinesAreSkipped() {
        let broken = """
        {not json
        {"type":"assistant","cwd":"/tmp","message":{"content":[{"type":"tool_use","name":"Bash","input":{"command":"ls"}}]}}
        {partial
        """
        XCTAssertEqual(ClaudeActivity.summarize(tail: broken)?.summary, "Bash: ls")
    }

    func testNoAssistantLineReturnsNil() {
        XCTAssertNil(ClaudeActivity.summarize(tail: #"{"type":"user","message":{}}"#))
    }
}
