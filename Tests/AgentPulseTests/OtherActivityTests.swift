import XCTest
@testable import AgentPulseCore

final class CodexActivityTests: XCTestCase {
    func testFunctionCallSummary() throws {
        let tail = #"""
        {"payload":{"type":"function_call","name":"shell","arguments":"{\"command\":\"npm test\",\"timeout\":1000}"},"type":"response_item"}
        """#
        let summary = try XCTUnwrap(CodexActivity.summarize(tail: tail))
        XCTAssertEqual(summary.summary, "shell: npm test")
    }

    func testAgentMessageAndReasoning() throws {
        let message = #"""
        {"payload":{"type":"agent_message","message":"テストを実行しました"},"type":"response_item"}
        """#
        XCTAssertEqual(try XCTUnwrap(CodexActivity.summarize(tail: message)).summary, "テストを実行しました")

        let reasoning = #"""
        {"payload":{"type":"reasoning","summary":[{"type":"summary_text","text":"構成を検討中"}]},"type":"response_item"}
        """#
        XCTAssertEqual(try XCTUnwrap(CodexActivity.summarize(tail: reasoning)).summary, "構成を検討中")
    }

    func testCWDFromSessionMeta() {
        let head = #"""
        {"type":"session_meta","payload":{"cwd":"/Users/me/proj","id":"x"}}
        """#
        XCTAssertEqual(CodexActivity.cwd(head: head), "/Users/me/proj")
        XCTAssertNil(CodexActivity.cwd(head: "{}"))
    }
}

final class OpenCodeActivityTests: XCTestCase {
    func testToolAndTextSummaries() {
        let tool = #"""
        {"content":[{"type":"tool","name":"bash","state":{"input":{"command":"npm test"}}}]}
        """#
        XCTAssertEqual(OpenCodeActivity.summarize(dataJSON: tool), "bash: npm test")

        let text = #"""
        {"content":[{"type":"text","text":"修正を反映します"}]}
        """#
        XCTAssertEqual(OpenCodeActivity.summarize(dataJSON: text), "修正を反映します")

        XCTAssertEqual(OpenCodeActivity.summarize(dataJSON: "not json"), "実行中")
    }
}

final class DSHActivityTests: XCTestCase {
    func testCWDFromDirectoryName() {
        XCTAssertEqual(
            DSHActivity.cwd(fromDirectoryName: "--Users-foo-bar--"),
            "/Users/foo/bar"
        )
        XCTAssertNil(DSHActivity.cwd(fromDirectoryName: "--"))
    }

    func testSummarizeLastEvent() {
        let decompressed = """
        {"type":"step/start","data":{"step":1}}
        {"type":"tool/call","data":{"name":"bash","arguments":"{\\"command\\":\\"npm test\\"}"}}
        {"type":"job/registered","data":{"kind":"bash"}}
        {"type":"tool/result","data":{}}
        """
        XCTAssertEqual(DSHActivity.summarize(decompressed: decompressed), "bash: npm test")
        XCTAssertEqual(DSHActivity.summarize(decompressed: decompressed + "\n{\"type\":\"turn/end\"}"), "ターン完了")
        XCTAssertEqual(DSHActivity.summarize(decompressed: "garbage"), "実行中")
    }

    func testCwdPrefersExistingHyphenatedDirectories() {
        let existing: Set<String> = ["/Users", "/Users/foo", "/Users/foo/my-app"]
        XCTAssertEqual(
            DSHActivity.cwd(fromDirectoryName: "--Users-foo-my-app--", exists: existing.contains),
            "/Users/foo/my-app"
        )
    }
}
