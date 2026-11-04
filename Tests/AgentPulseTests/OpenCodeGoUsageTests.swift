import XCTest
@testable import AgentPulseCore

final class OpenCodeGoUsageTests: XCTestCase {
    private let price = OpenCodeGoUsage.Price(input: 2, cachedInput: 0.25, output: 6)

    func testCostUsesPerMillionPricing() {
        let tokens = OpenCodeGoUsage.Tokens(input: 1_000_000, output: 1_000_000)
        XCTAssertEqual(OpenCodeGoUsage.cost(tokens: tokens, price: price), 8.0, accuracy: 0.0001)
    }

    func testReasoningCountsAsOutput() {
        let tokens = OpenCodeGoUsage.Tokens(reasoning: 500_000)
        XCTAssertEqual(OpenCodeGoUsage.cost(tokens: tokens, price: price), 3.0, accuracy: 0.0001)
    }

    func testCacheReadAndWritePricing() {
        let cacheRead = OpenCodeGoUsage.Tokens(cacheRead: 1_000_000)
        XCTAssertEqual(OpenCodeGoUsage.cost(tokens: cacheRead, price: price), 0.25, accuracy: 0.0001)

        let cacheWrite = OpenCodeGoUsage.Tokens(cacheWrite: 1_000_000)
        XCTAssertEqual(OpenCodeGoUsage.cost(tokens: cacheWrite, price: price), 2.0, accuracy: 0.0001)
    }

    func testParsePriceFromCatalog() throws {
        let catalog = #"""
        {"updatedAt":1,"body":"{\"opencode-go\":{\"models\":{\"deepseek-v4.1-flash\":{\"cost\":{\"text\":{\"input\":{\"price\":0.5,\"cache\":{\"read\":0.05,\"write\":0.6}},\"output\":{\"price\":1.5}}}}}}}"}
        """#
        let parsed = try XCTUnwrap(
            OpenCodeGoUsage.parsePrice(catalogValue: catalog, modelId: "deepseek-v4.1-flash")
        )
        XCTAssertEqual(parsed.input, 0.5, accuracy: 0.0001)
        XCTAssertEqual(parsed.cachedInput, 0.05, accuracy: 0.0001)
        XCTAssertEqual(parsed.output, 1.5, accuracy: 0.0001)
    }

    func testParsePriceAcceptsObjectBodyAndPrefixedModelId() throws {
        let catalog = #"""
        {"body":{"opencode-go":{"models":{"opencode-go/foo":{"cost":{"text":{"input":{"price":1},"output":{"price":2}}}}}}}}
        """#
        let parsed = try XCTUnwrap(OpenCodeGoUsage.parsePrice(catalogValue: catalog, modelId: "foo"))
        XCTAssertEqual(parsed.input, 1, accuracy: 0.0001)
        XCTAssertEqual(parsed.cachedInput, 1, accuracy: 0.0001)
        XCTAssertEqual(parsed.output, 2, accuracy: 0.0001)
    }

    func testWindowsConvertCostToPercent() {
        let now = Date(timeIntervalSince1970: 1_793_404_800)
        let record = OpenCodeGoUsage.UsageRecord(
            modelId: "foo",
            tokens: OpenCodeGoUsage.Tokens(input: 1_000_000),
            createdAt: now.addingTimeInterval(-60)
        )
        let windows = OpenCodeGoUsage.windows(
            records: [record],
            prices: ["foo": price],
            limits: .init(fiveHourUSD: 12, weeklyUSD: 30, monthlyUSD: 60),
            now: now
        )

        XCTAssertEqual(windows.count, 3)
        XCTAssertEqual(windows[0].label, "5h（推定）")
        XCTAssertEqual(windows[0].usedPercent, 2 / 12 * 100, accuracy: 0.001)
        XCTAssertEqual(windows[1].usedPercent, 2 / 30 * 100, accuracy: 0.001)
        XCTAssertEqual(windows[2].usedPercent, 2 / 60 * 100, accuracy: 0.001)
        XCTAssertTrue(windows[0].note?.contains("$2.00") == true)
    }

    func testOldRecordsFallOutsideWindows() {
        let now = Date(timeIntervalSince1970: 1_793_404_800)
        let record = OpenCodeGoUsage.UsageRecord(
            modelId: "foo",
            tokens: OpenCodeGoUsage.Tokens(input: 1_000_000),
            createdAt: now.addingTimeInterval(-8 * 86_400)
        )
        let windows = OpenCodeGoUsage.windows(
            records: [record],
            prices: ["foo": price],
            limits: .init(),
            now: now
        )
        XCTAssertEqual(windows[0].usedPercent, 0)  // 5h
        XCTAssertEqual(windows[1].usedPercent, 0)  // 7d
        XCTAssertGreaterThan(windows[2].usedPercent, 0)  // 30d
    }

    func testRecordFromCurrentSchema() throws {
        let json = #"""
        {"time":{"created":1793404860000},"model":{"id":"deepseek-v4.1-flash","providerID":"opencode-go"},"tokens":{"input":1000,"output":200,"reasoning":50,"cache":{"read":10,"write":5}}}
        """#
        let record = try XCTUnwrap(OpenCodeGoUsage.record(fromJSON: json, fallbackTime: nil))
        XCTAssertEqual(record.modelId, "deepseek-v4.1-flash")
        XCTAssertEqual(record.tokens.input, 1000)
        XCTAssertEqual(record.tokens.cacheRead, 10)
        XCTAssertEqual(record.tokens.cacheWrite, 5)
        XCTAssertEqual(record.createdAt.timeIntervalSince1970, 1_793_404_860, accuracy: 0.001)
    }

    func testRecordFromLegacySchemaAndOtherProviders() throws {
        let legacy = #"""
        {"providerID":"opencode-go","modelID":"gpt-5","time":{"created":1793404860000},"tokens":{"input":10,"output":20}}
        """#
        let record = try XCTUnwrap(OpenCodeGoUsage.record(fromJSON: legacy, fallbackTime: nil))
        XCTAssertEqual(record.modelId, "gpt-5")

        let other = #"""
        {"model":{"providerID":"anthropic","id":"claude"},"tokens":{"input":1},"time":{"created":1793404860000}}
        """#
        XCTAssertNil(OpenCodeGoUsage.record(fromJSON: other, fallbackTime: nil))
    }

    func testParsesConsoleLimits() {
        let json = #"""
        {"location":{"directory":"/x"},"data":{"workspace":{"id":"w","usageURL":"u"},"budgets":[],
          "go":{"rolling":{"percent":12.5,"limited":false,"resetsAt":1793800000000},
                "weekly":{"percent":100,"limited":true,"resetsAt":1794000000000},
                "monthly":{"percent":40,"limited":false,"resetsAt":1795000000000}}}}
        """#
        guard case .windows(let windows) = OpenCodeGoUsage.parse(limitsResponse: Data(json.utf8)) else {
            return XCTFail("expected windows")
        }
        XCTAssertEqual(windows.map(\.label), ["5h", "7d", "月"])
        XCTAssertEqual(windows.map(\.usedPercent), [12.5, 100, 40])
        XCTAssertEqual(windows[0].resetsAt, Date(timeIntervalSince1970: 1_793_800_000))
        XCTAssertEqual(windows[1].note, "上限到達")
        XCTAssertNil(windows[0].note)
    }

    func testNullDataMeansNotSignedIn() {
        let json = #"{"location":{"directory":"/x"},"data":null}"#
        guard case .notSignedIn = OpenCodeGoUsage.parse(limitsResponse: Data(json.utf8)) else {
            return XCTFail("expected notSignedIn")
        }
    }
}
