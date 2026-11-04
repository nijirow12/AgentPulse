import XCTest
@testable import AgentPulseCore

final class CodexUsageTests: XCTestCase {
    // 2026-11-01T00:00:00Z — before both reset timestamps.
    private let now = Date(timeIntervalSince1970: 1_793_404_800)

    private let line = #"""
    {"timestamp":"2026-11-01T00:00:00Z","type":"event_msg","payload":{"type":"token_count","rate_limits":{"primary":{"used_percent":25.0,"window_minutes":300,"resets_at":1793530957},"secondary":{"used_percent":88.0,"window_minutes":10080,"resets_at":1793780859},"plan_type":"plus"}}}
    """#

    func testParsesPrimaryAndSecondary() throws {
        let windows = try XCTUnwrap(CodexUsage.parse(line: line, now: now))
        XCTAssertEqual(windows.count, 2)
        XCTAssertEqual(windows[0].label, "5h")
        XCTAssertEqual(windows[0].usedPercent, 25.0, accuracy: 0.001)
        XCTAssertEqual(windows[0].resetsAt, Date(timeIntervalSince1970: 1_793_530_957))
        XCTAssertEqual(windows[1].label, "7d")
        XCTAssertEqual(windows[1].usedPercent, 88.0, accuracy: 0.001)
    }

    func testFindsNestedRateLimits() throws {
        let nested = #"{"payload":{"info":{"rate_limits":{"primary":{"used_percent":10,"window_minutes":300}}}}}"#
        let windows = try XCTUnwrap(CodexUsage.parse(line: nested, now: now))
        XCTAssertEqual(windows.first?.usedPercent, 10)
    }

    func testIgnoresLinesWithoutRateLimits() {
        XCTAssertNil(CodexUsage.parse(line: #"{"type":"session_meta"}"#, now: now))
    }

    func testExpiredWindowIsTreatedAsReset() throws {
        let later = Date(timeIntervalSince1970: 1_793_800_000)
        let windows = try XCTUnwrap(CodexUsage.parse(line: line, now: later))
        XCTAssertEqual(windows[0].usedPercent, 0)
        XCTAssertNotNil(windows[0].note)
    }

    func testWindowLabelFormatting() {
        XCTAssertEqual(DurationText.windowLabel(minutes: 300), "5h")
        XCTAssertEqual(DurationText.windowLabel(minutes: 10_080), "7d")
        XCTAssertEqual(DurationText.windowLabel(minutes: 1_440), "1d")
        XCTAssertEqual(DurationText.windowLabel(minutes: 90), "90m")
        XCTAssertEqual(DurationText.windowLabel(minutes: nil), "—")
    }

    func testParsesUsageEndpointResponse() throws {
        let json = #"""
        {"plan_type":"plus","rate_limit":{"allowed":false,"limit_reached":true,
          "primary_window":{"used_percent":0,"limit_window_seconds":18000,"reset_after_seconds":18000,"reset_at":1793788115},
          "secondary_window":{"used_percent":100,"limit_window_seconds":604800,"reset_after_seconds":10745,"reset_at":1793780860}}}
        """#
        let windows = try XCTUnwrap(CodexUsage.parse(usageResponse: Data(json.utf8)))
        XCTAssertEqual(windows.map(\.label), ["5h", "7d"])
        XCTAssertEqual(windows.map(\.usedPercent), [0, 100])
        XCTAssertEqual(windows[1].resetsAt, Date(timeIntervalSince1970: 1_793_780_860))
        XCTAssertEqual(windows[1].note, "上限到達")
        XCTAssertNil(windows[0].note)
    }

    func testCredentialsAndJWTExpiry() throws {
        // payload {"exp":1793800000}
        let payload = Data(#"{"exp":1793800000}"#.utf8).base64EncodedString()
            .replacingOccurrences(of: "=", with: "")
        let json = #"{"tokens":{"access_token":"h.\#(payload).s","account_id":"acct"}}"#
        let credentials = try XCTUnwrap(CodexUsage.parseCredentials(Data(json.utf8)))
        XCTAssertEqual(credentials.accountId, "acct")
        XCTAssertEqual(credentials.expiresAt, Date(timeIntervalSince1970: 1_793_800_000))
        XCTAssertNil(CodexUsage.parseCredentials(Data(#"{"tokens":{}}"#.utf8)))
    }
}
