import Foundation

// MARK: - Limits

/// One usage window of a provider (e.g. the 5 hour bucket or the 7 day bucket).
public struct UsageWindow: Identifiable, Sendable, Hashable, Codable {
    public var id: String
    public var label: String
    public var usedPercent: Double
    public var resetsAt: Date?
    /// Small annotation such as "リセット済み（最新値未取得）".
    public var note: String?

    public init(
        id: String? = nil,
        label: String,
        usedPercent: Double,
        resetsAt: Date? = nil,
        note: String? = nil
    ) {
        self.id = id ?? label
        self.label = label
        self.usedPercent = usedPercent
        self.resetsAt = resetsAt
        self.note = note
    }

    /// Clamped percentage, convenient for progress bars.
    public var clampedPercent: Double {
        min(max(usedPercent, 0), 100)
    }
}

public enum ProviderKind: String, Sendable, CaseIterable, Identifiable {
    case claude
    case codex
    case opencodeGo

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .claude: "Claude"
        case .codex: "Codex (GPT)"
        case .opencodeGo: "OpenCode Go"
        }
    }
}

public struct ProviderUsage: Identifiable, Sendable {
    public var id: ProviderKind
    public var windows: [UsageWindow]
    /// When the underlying data was produced (not when it was fetched).
    public var asOf: Date?
    public var error: String?
    public var footnote: String?

    public init(
        id: ProviderKind,
        windows: [UsageWindow] = [],
        asOf: Date? = nil,
        error: String? = nil,
        footnote: String? = nil
    ) {
        self.id = id
        self.windows = windows
        self.asOf = asOf
        self.error = error
        self.footnote = footnote
    }

    /// Highest used percentage across the windows, if any.
    public var maxPercent: Double? {
        windows.map(\.usedPercent).max()
    }
}

// MARK: - Activity

public enum AgentTool: String, Sendable, CaseIterable, Identifiable {
    case claude
    case codex
    case opencode
    case dsh

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .claude: "Claude"
        case .codex: "Codex"
        case .opencode: "OpenCode"
        case .dsh: "DSH"
        }
    }
}

public struct AgentSession: Identifiable, Sendable {
    public var id: String
    public var tool: AgentTool
    public var cwd: String?
    public var lastUpdate: Date
    public var summary: String
    public var pid: Int32?
    public var cpu: Double?
    /// A live process with no session log to describe what it is doing.
    public var isProcessOnly: Bool

    public init(
        id: String,
        tool: AgentTool,
        cwd: String? = nil,
        lastUpdate: Date,
        summary: String,
        pid: Int32? = nil,
        cpu: Double? = nil,
        isProcessOnly: Bool = false
    ) {
        self.id = id
        self.tool = tool
        self.cwd = cwd
        self.lastUpdate = lastUpdate
        self.summary = summary
        self.pid = pid
        self.cpu = cpu
        self.isProcessOnly = isProcessOnly
    }

    /// Last path component of the working directory.
    public var directoryName: String {
        guard let cwd, !cwd.isEmpty else { return "—" }
        let name = (cwd as NSString).lastPathComponent
        return name.isEmpty ? cwd : name
    }

    /// `true` when a matching process is running.
    public var isRunning: Bool { pid != nil }

    /// A process-only row that is not using the CPU is idle, not working.
    public var isIdleProcess: Bool { isProcessOnly && (cpu ?? 0) < 1 }

    /// Doing something right now: its log moved in the last 30 seconds, or its process is
    /// using the CPU (e.g. a long build where the log stays quiet).
    public func isWorking(now: Date = Date()) -> Bool {
        if pid != nil, (cpu ?? 0) >= 1 { return true }
        return !isProcessOnly && now.timeIntervalSince(lastUpdate) <= 30
    }
}
