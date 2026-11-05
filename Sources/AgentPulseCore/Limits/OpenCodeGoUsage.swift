import Foundation

/// OpenCode Go allowance: exact from the local opencode service when it is signed in to an
/// OpenCode Console workspace, otherwise estimated from the local SQLite DB.
public enum OpenCodeGoUsage {
    // MARK: Types

    public struct Tokens: Sendable, Equatable {
        public var input: Double
        public var output: Double
        public var reasoning: Double
        public var cacheRead: Double
        public var cacheWrite: Double

        public init(
            input: Double = 0,
            output: Double = 0,
            reasoning: Double = 0,
            cacheRead: Double = 0,
            cacheWrite: Double = 0
        ) {
            self.input = input
            self.output = output
            self.reasoning = reasoning
            self.cacheRead = cacheRead
            self.cacheWrite = cacheWrite
        }
    }

    /// USD per 1M tokens.
    public struct Price: Sendable, Equatable {
        public var input: Double
        public var cachedInput: Double
        public var output: Double

        public init(input: Double, cachedInput: Double, output: Double) {
            self.input = input
            self.cachedInput = cachedInput
            self.output = output
        }
    }

    public struct Limits: Sendable, Equatable {
        public var fiveHourUSD: Double
        public var weeklyUSD: Double
        public var monthlyUSD: Double

        public init(fiveHourUSD: Double = 12, weeklyUSD: Double = 30, monthlyUSD: Double = 60) {
            self.fiveHourUSD = fiveHourUSD
            self.weeklyUSD = weeklyUSD
            self.monthlyUSD = monthlyUSD
        }
    }

    public struct UsageRecord: Sendable, Equatable {
        public var modelId: String
        public var tokens: Tokens
        public var createdAt: Date

        public init(modelId: String, tokens: Tokens, createdAt: Date) {
            self.modelId = modelId
            self.tokens = tokens
            self.createdAt = createdAt
        }
    }

    // MARK: Pricing (pure)

    /// text price for one model: `input.price`, `input.cache.read`, `output.price`.
    public static func parsePrice(catalogValue: String, modelId: String) -> Price? {
        guard
            let data = catalogValue.data(using: .utf8),
            let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }

        var body: [String: Any]?
        if let string = root["body"] as? String {
            body = (try? JSONSerialization.jsonObject(with: Data(string.utf8))) as? [String: Any]
        } else if let dictionary = root["body"] as? [String: Any] {
            body = dictionary
        } else {
            body = root
        }

        guard
            let providers = body?["opencode-go"] as? [String: Any],
            let models = providers["models"] as? [String: Any]
        else { return nil }

        let candidates = [modelId, "opencode-go/\(modelId)"]
        guard let model = candidates.lazy.compactMap({ models[$0] as? [String: Any] }).first,
              let cost = model["cost"] as? [String: Any],
              let text = cost["text"] as? [String: Any]
        else { return nil }

        let input = text["input"] as? [String: Any]
        let inputPrice = number(input?["price"]) ?? 0
        let cacheRead = number((input?["cache"] as? [String: Any])?["read"]) ?? inputPrice
        let outputPrice = number((text["output"] as? [String: Any])?["price"]) ?? 0

        return Price(input: inputPrice, cachedInput: cacheRead, output: outputPrice)
    }

    /// Estimated USD cost of a token bundle.
    public static func cost(tokens: Tokens, price: Price) -> Double {
        let inputCost = tokens.input * price.input
        let cacheReadCost = tokens.cacheRead * price.cachedInput
        let cacheWriteCost = tokens.cacheWrite * price.input
        let outputCost = (tokens.output + tokens.reasoning) * price.output
        return (inputCost + cacheReadCost + cacheWriteCost + outputCost) / 1_000_000
    }

    static func sum(records: [UsageRecord], prices: [String: Price], since: Date) -> Double {
        records.reduce(0) { total, record in
            guard record.createdAt >= since, let price = prices[record.modelId] else { return total }
            return total + cost(tokens: record.tokens, price: price)
        }
    }

    /// Builds the three windows from already-parsed records (pure, testable).
    public static func windows(
        records: [UsageRecord],
        prices: [String: Price],
        limits: Limits,
        now: Date = Date()
    ) -> [UsageWindow] {
        func window(_ label: String, _ id: String, _ seconds: TimeInterval, _ limit: Double) -> UsageWindow {
            let spend = sum(records: records, prices: prices, since: now.addingTimeInterval(-seconds))
            let percent = limit > 0 ? min(100, spend / limit * 100) : 0
            return UsageWindow(
                id: id,
                label: "\(label)（推定）",
                usedPercent: percent,
                resetsAt: nil,
                note: String(format: "$%.2f / $%.0f", spend, limit)
            )
        }

        return [
            window("5h", "fiveHour", 5 * 3_600, limits.fiveHourUSD),
            window("7d", "weekly", 7 * 86_400, limits.weeklyUSD),
            window("30d", "monthly", 30 * 86_400, limits.monthlyUSD),
        ]
    }

    // MARK: I/O

    public static var defaultDatabasePath: String {
        FileManager.default.homeDirectoryForCurrentUser
            .appending(path: ".local/share/opencode/opencode.db").path
    }

    public static func load(
        limits: Limits,
        databasePath: String = defaultDatabasePath,
        now: Date = Date()
    ) -> ProviderUsage {
        guard let db = SQLiteReader(path: databasePath) else {
            return ProviderUsage(
                id: .opencodeGo,
                error: "ローカル DB を開けませんでした。",
                footnote: footnote
            )
        }

        let prices = loadPrices(db: db)
        let since = now.addingTimeInterval(-30 * 86_400)
        let records = loadRecords(db: db, since: since)
        guard !records.isEmpty else {
            return ProviderUsage(
                id: .opencodeGo,
                windows: windows(records: [], prices: prices, limits: limits, now: now),
                asOf: nil,
                error: "直近 30 日の記録がありません。",
                footnote: footnote
            )
        }

        let windows = windows(records: records, prices: prices, limits: limits, now: now)
        let latest = records.map(\.createdAt).max()
        return ProviderUsage(
            id: .opencodeGo,
            windows: windows,
            asOf: latest,
            footnote: footnote
        )
    }

    private static let footnote = "ローカル DB から推定（DSH の利用は含まれません）"

    /// modelId → price for every model that has text pricing.
    static func loadPrices(db: SQLiteReader) -> [String: Price] {
        // Cheap fingerprint of the catalog row so the 11MB JSON is not re-parsed every minute.
        let stampSQL = #"SELECT substr(value, instr(value, '"updatedAt":') + 12, 20) AS stamp FROM kv WHERE key = ?"#
        let stamp = db.query(stampSQL, [.text("models-dev:v2:catalog")])?
            .first?["stamp"]?.stringValue ?? ""

        if !stamp.isEmpty, let cached = priceCache.value(for: stamp) {
            return cached
        }

        let prices = parseCatalog(db: db)
        if !stamp.isEmpty, !prices.isEmpty {
            priceCache.store(prices, for: stamp)
        }
        return prices
    }

    private static func parseCatalog(db: SQLiteReader) -> [String: Price] {
        guard
            let rows = db.query("SELECT value FROM kv WHERE key = ?", [.text("models-dev:v2:catalog")]),
            let value = rows.first?["value"]?.stringValue,
            let data = value.data(using: .utf8),
            let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return [:] }

        var body: [String: Any]?
        if let string = root["body"] as? String {
            body = (try? JSONSerialization.jsonObject(with: Data(string.utf8))) as? [String: Any]
        } else if let dictionary = root["body"] as? [String: Any] {
            body = dictionary
        }
        guard
            let models = (body?["opencode-go"] as? [String: Any])?["models"] as? [String: Any]
        else { return [:] }

        var prices: [String: Price] = [:]
        for (id, value) in models {
            guard
                let model = value as? [String: Any],
                let cost = model["cost"] as? [String: Any],
                let text = cost["text"] as? [String: Any]
            else { continue }
            let input = text["input"] as? [String: Any]
            let inputPrice = number(input?["price"]) ?? 0
            let cacheRead = number((input?["cache"] as? [String: Any])?["read"]) ?? inputPrice
            let outputPrice = number((text["output"] as? [String: Any])?["price"]) ?? 0
            prices[id] = Price(input: inputPrice, cachedInput: cacheRead, output: outputPrice)
        }
        return prices
    }

    private static let priceCache = PriceCache()

    /// Assistant rows carry the whole reply text; SQLite filters to opencode-go and hands back
    /// only the fields `record(fromJSON:)` reads, so Swift never parses the large payloads.
    private static let isOpenCodeGo =
        "coalesce(json_extract(data, '$.model.providerID'), json_extract(data, '$.providerID')) = 'opencode-go'"
    private static let slimData = """
        json_object('model', json(json_extract(data, '$.model')), \
        'providerID', json_extract(data, '$.providerID'), \
        'modelID', json_extract(data, '$.modelID'), \
        'tokens', json(json_extract(data, '$.tokens')), \
        'time', json(json_extract(data, '$.time')))
        """

    static func loadRecords(db: SQLiteReader, since: Date) -> [UsageRecord] {
        let sinceMilliseconds = Int64(since.timeIntervalSince1970 * 1_000)
        var records: [UsageRecord] = []

        // Current schema.
        if let rows = db.query(
            "SELECT time_created, \(slimData) AS data FROM session_message WHERE type = 'assistant' AND time_created > ? AND \(isOpenCodeGo)",
            [.integer(sinceMilliseconds)]
        ) {
            for row in rows {
                if let record = record(fromJSON: row["data"]?.stringValue, fallbackTime: row["time_created"]) {
                    records.append(record)
                }
            }
        }

        // Legacy schema.
        if let rows = db.query(
            "SELECT time_created, \(slimData) AS data FROM message WHERE time_created > ? AND \(isOpenCodeGo)",
            [.integer(sinceMilliseconds)]
        ) {
            for row in rows {
                if let record = record(fromJSON: row["data"]?.stringValue, fallbackTime: row["time_created"]) {
                    records.append(record)
                }
            }
        }

        return records
    }

    /// Accepts both `session_message` and legacy `message` payloads.
    static func record(fromJSON json: String?, fallbackTime: SQLiteValue?) -> UsageRecord? {
        guard
            let json,
            let data = json.data(using: .utf8),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }

        let model = object["model"] as? [String: Any]
        let provider = (model?["providerID"] as? String) ?? (object["providerID"] as? String)
        guard provider == "opencode-go" else { return nil }

        let modelId = (model?["id"] as? String)
            ?? (model?["modelID"] as? String)
            ?? (object["modelID"] as? String)
            ?? (object["modelId"] as? String)
        guard let modelId else { return nil }

        let tokens = object["tokens"] as? [String: Any] ?? [:]
        let cache = tokens["cache"] as? [String: Any]
        let usage = Tokens(
            input: number(tokens["input"]) ?? 0,
            output: number(tokens["output"]) ?? 0,
            reasoning: number(tokens["reasoning"]) ?? 0,
            cacheRead: number(cache?["read"]) ?? 0,
            cacheWrite: number(cache?["write"]) ?? 0
        )

        let time = object["time"] as? [String: Any]
        let milliseconds = number(time?["created"]) ?? fallbackTime?.doubleValue
        guard let milliseconds else { return nil }

        return UsageRecord(
            modelId: modelId,
            tokens: usage,
            createdAt: Date(timeIntervalSince1970: milliseconds / 1_000)
        )
    }

    private static func number(_ value: Any?) -> Double? {
        if let value = value as? Double { return value }
        if let value = value as? Int { return Double(value) }
        if let value = value as? NSNumber { return value.doubleValue }
        if let value = value as? String { return Double(value) }
        return nil
    }
}

extension OpenCodeGoUsage {
    // MARK: Live allowance from the opencode service

    /// `~/.config/opencode/service.json`: the background service's port and password. Read-only.
    public static var serviceFile: URL {
        FileManager.default.homeDirectoryForCurrentUser.appending(path: ".config/opencode/service.json")
    }

    public enum LiveResult: Sendable {
        case windows([UsageWindow])
        /// The service answered but is not signed in to an OpenCode Console workspace.
        case notSignedIn
        case unavailable(String)
    }

    /// `data.go.{rolling,weekly,monthly}` of `GET /api/experimental/usage/limits`.
    public static func parse(limitsResponse data: Data) -> LiveResult {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return .unavailable("応答を解釈できませんでした")
        }
        guard let info = root["data"] as? [String: Any] else { return .notSignedIn }
        guard let go = info["go"] as? [String: Any] else {
            return .unavailable("このワークスペースに OpenCode Go がありません")
        }

        let meters: [(key: String, label: String)] = [("rolling", "5h"), ("weekly", "7d"), ("monthly", "月")]
        let windows = meters.compactMap { meter -> UsageWindow? in
            guard let entry = go[meter.key] as? [String: Any],
                  let percent = number(entry["percent"])
            else { return nil }
            return UsageWindow(
                id: meter.key,
                label: meter.label,
                usedPercent: percent,
                resetsAt: number(entry["resetsAt"]).map { Date(timeIntervalSince1970: $0 / 1_000) },
                note: (entry["limited"] as? Bool) == true ? "上限到達" : nil
            )
        }
        return windows.isEmpty ? .unavailable("利用枠が空でした") : .windows(windows)
    }

    public static func fetchLive(retryAfterStarting: Bool = true) async -> LiveResult {
        guard
            let data = try? Data(contentsOf: serviceFile),
            let service = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let port = number(service["port"]).map(Int.init),
            let password = service["password"] as? String,
            let url = URL(string: "http://127.0.0.1:\(port)/api/experimental/usage/limits")
        else { return .unavailable("opencode サービスの情報が見つかりません") }

        var request = URLRequest(url: url)
        request.timeoutInterval = 10
        let basic = Data("opencode:\(password)".utf8).base64EncodedString()
        request.setValue("Basic \(basic)", forHTTPHeaderField: "Authorization")

        do {
            let (body, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard (200...299).contains(status) else { return .unavailable("opencode サービスが HTTP \(status) を返しました") }
            return parse(limitsResponse: body)
        } catch {
            // The service stops with the opencode desktop app or a restart; start it and ask again.
            guard retryAfterStarting, startService() else {
                return .unavailable("opencode サービスに接続できません")
            }
            try? await Task.sleep(for: .seconds(2))
            return await fetchLive(retryAfterStarting: false)
        }
    }

    // MARK: Starting the background service

    /// opencode executables that can start the service, best first: the desktop app's bundled
    /// CLI (newest), then the usual install locations, then nvm-installed copies.
    static func opencodeExecutables(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> [String] {
        let fm = FileManager.default
        var candidates: [String] = []
        let desktop = home.appending(path: "Library/Application Support/ai.opencode.desktop/cli")
        if let versions = try? fm.contentsOfDirectory(atPath: desktop.path) {
            for version in versions.sorted(by: { $0.compare($1, options: .numeric) == .orderedDescending }) {
                candidates.append(desktop.appending(path: "\(version)/opencode-cli").path)
            }
        }
        candidates += [
            home.appending(path: ".opencode/bin/opencode").path,
            "/opt/homebrew/bin/opencode",
            "/usr/local/bin/opencode",
        ]
        let nvm = home.appending(path: ".nvm/versions/node")
        if let nodes = try? fm.contentsOfDirectory(atPath: nvm.path) {
            for node in nodes.sorted(by: { $0.compare($1, options: .numeric) == .orderedDescending }) {
                candidates.append(nvm.appending(path: "\(node)/bin/opencode").path)
            }
        }
        return candidates.filter { fm.isExecutableFile(atPath: $0) }
    }

    /// Runs `opencode service start`, at most once every 5 minutes so a Mac without opencode
    /// (or with a broken install) is not hammered every refresh. Returns whether it succeeded.
    static func startService(now: Date = Date()) -> Bool {
        guard serviceStarts.claim(now: now, every: 300) else { return false }
        for executable in opencodeExecutables() {
            // nvm copies are Node scripts and need their own bin directory on PATH.
            let bin = (executable as NSString).deletingLastPathComponent
            let result = Shell.run(
                executable, ["service", "start"],
                timeout: 20,
                environment: ["PATH": "\(bin):/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"]
            )
            if result.succeeded { return true }
        }
        return false
    }

    private static let serviceStarts = Throttle()
}

/// Lets an action through at most once per interval.
private final class Throttle: @unchecked Sendable {
    private let lock = NSLock()
    private var last: Date?

    func claim(now: Date, every interval: TimeInterval) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if let last, now.timeIntervalSince(last) < interval { return false }
        last = now
        return true
    }
}

extension OpenCodeGoUsage {

    /// Exact allowance when available, otherwise the local estimate with the reason noted.
    public static func fetch(limits: Limits) async -> ProviderUsage {
        let reason: String
        switch await fetchLive() {
        case .windows(let windows):
            return ProviderUsage(
                id: .opencodeGo,
                windows: windows,
                asOf: Date(),
                footnote: "OpenCode Console の利用枠（DSH の利用も含む）"
            )
        case .notSignedIn:
            reason = "Console 未サインイン（opencode auth login opencode）"
        case .unavailable(let message):
            reason = message
        }
        var estimate = load(limits: limits)
        estimate.footnote = "\(reason)のため、ローカル DB から推定（DSH の利用は含まれません）"
        return estimate
    }
}

/// Catalog fingerprint → prices, so the huge catalog JSON is parsed once per update.
private final class PriceCache: @unchecked Sendable {
    private let lock = NSLock()
    private var stamp: String?
    private var prices: [String: OpenCodeGoUsage.Price] = [:]

    func value(for stamp: String) -> [String: OpenCodeGoUsage.Price]? {
        lock.lock()
        defer { lock.unlock() }
        guard self.stamp == stamp, !prices.isEmpty else { return nil }
        return prices
    }

    func store(_ prices: [String: OpenCodeGoUsage.Price], for stamp: String) {
        lock.lock()
        self.stamp = stamp
        self.prices = prices
        lock.unlock()
    }
}
