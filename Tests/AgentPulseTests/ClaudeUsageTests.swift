import XCTest
@testable import AgentPulseCore

final class ClaudeUsageTests: XCTestCase {
    private let json = #"""
    {
      "five_hour": {"utilization": 42.5, "resets_at": "2026-11-03T20:00:00.123456+00:00"},
      "seven_day": {"utilization": 88, "resets_at": "2026-11-08T00:00:00Z"},
      "seven_day_opus": null,
      "seven_day_sonnet": {"utilization": 12, "resets_at": null},
      "extra_metric": {"something": 1}
    }
    """#

    func testParsesGenericWindows() throws {
        let windows = try XCTUnwrap(ClaudeUsage.parse(json: json))
        XCTAssertEqual(windows.count, 3, "null / non-usage keys must be skipped")

        XCTAssertEqual(windows[0].label, "5h")
        XCTAssertEqual(windows[0].usedPercent, 42.5, accuracy: 0.001)
        XCTAssertNotNil(windows[0].resetsAt)

        XCTAssertEqual(windows[1].label, "7d")
        XCTAssertEqual(windows[1].usedPercent, 88, accuracy: 0.001)

        XCTAssertEqual(windows[2].label, "7d Sonnet")
        XCTAssertEqual(windows[2].usedPercent, 12, accuracy: 0.001)
        XCTAssertNil(windows[2].resetsAt)
    }

    func testLabels() {
        XCTAssertEqual(ClaudeUsage.label(forKey: "five_hour"), "5h")
        XCTAssertEqual(ClaudeUsage.label(forKey: "seven_day"), "7d")
        XCTAssertEqual(ClaudeUsage.label(forKey: "seven_day_opus"), "7d Opus")
        XCTAssertEqual(ClaudeUsage.label(forKey: "thirty_day"), "30d")
        XCTAssertEqual(ClaudeUsage.label(forKey: "weird"), "Weird")
    }

    func testInvalidJSONReturnsNil() {
        XCTAssertNil(ClaudeUsage.parse(json: "not json"))
    }

    func testFractionalSecondsParsing() {
        XCTAssertNotNil(ISO8601.parse("2026-11-03T20:00:00.123456+00:00"))
        XCTAssertNotNil(ISO8601.parse("2026-11-03T20:00:00Z"))
        XCTAssertNil(ISO8601.parse(nil))
    }

    func testPrefersLimitsArray() throws {
        let json = #"""
        {
          "five_hour": {"utilization": 99, "resets_at": null},
          "limits": [
            {"kind": "session", "group": "session", "percent": 7, "resets_at": "2026-11-04T10:10:00.796914+00:00"},
            {"kind": "weekly_all", "group": "weekly", "percent": 10, "resets_at": "2026-11-09T03:00:00Z"},
            {"kind": "weekly_sonnet", "group": "weekly", "percent": 3, "resets_at": null},
            {"kind": "broken"}
          ]
        }
        """#
        let windows = try XCTUnwrap(ClaudeUsage.parse(json: json))
        XCTAssertEqual(windows.map(\.label), ["セッション", "週・全体", "週・Sonnet"])
        XCTAssertEqual(windows.map(\.usedPercent), [7, 10, 3])
        XCTAssertNotNil(windows[0].resetsAt)
    }

    func testCredentialsParsing() throws {
        let json = #"{"claudeAiOauth":{"accessToken":"tok","refreshToken":"r","expiresAt":1793800000000}}"#
        let credentials = try XCTUnwrap(ClaudeUsage.parseCredentials(Data(json.utf8)))
        XCTAssertEqual(credentials.accessToken, "tok")
        XCTAssertEqual(credentials.expiresAt, Date(timeIntervalSince1970: 1_793_800_000))
        XCTAssertNil(ClaudeUsage.parseCredentials(Data(#"{"claudeAiOauth":{}}"#.utf8)))
    }
}
