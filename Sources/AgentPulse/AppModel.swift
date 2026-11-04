import Foundation
import SwiftUI
import AgentPulseCore

/// Owns the periodic collection loops and publishes the results to the UI.
@MainActor
final class AppModel: ObservableObject {
    /// The app is a single menu-bar popover, so one shared instance keeps the loops alive.
    static let shared = AppModel()

    @Published private(set) var usages: [ProviderUsage] = []
    @Published private(set) var sessions: [AgentSession] = []
    @Published private(set) var lastRefresh: Date?
    @Published private(set) var isRefreshing = false
    @Published private(set) var preferences = Preferences()

    private var activityLoop: Task<Void, Never>?
    private var limitsLoop: Task<Void, Never>?

    private let activityInterval: TimeInterval = 5
    private let limitsInterval: TimeInterval = 60
    /// The Claude usage API rate-limits hard (and answers 429 with `Retry-After: 0`), so it is
    /// asked at most every 2 minutes, backing off up to 30 minutes after a 429. The schedule and
    /// the last good numbers survive restarts, so relaunching never triggers an extra request.
    private struct ClaudeSchedule: Codable {
        var windows: [UsageWindow] = []
        var asOf: Date?
        var nextFetch = Date.distantPast
        var backoff: TimeInterval = 0
    }

    private static let claudeScheduleKey = "claudeUsageSchedule"
    private let claudeInterval: TimeInterval = 120
    private let claudeMaxBackoff: TimeInterval = 1_800
    private var claudeSchedule = ClaudeSchedule()

    init() {
        SettingsKey.register()
        preferences = Preferences.load()
        if let data = UserDefaults.standard.data(forKey: Self.claudeScheduleKey),
           let saved = try? JSONDecoder().decode(ClaudeSchedule.self, from: data) {
            claudeSchedule = saved
            if !saved.windows.isEmpty {
                usages = [ProviderUsage(id: .claude, windows: saved.windows, asOf: saved.asOf)]
            }
        }
    }

    private func saveClaudeSchedule() {
        if let data = try? JSONEncoder().encode(claudeSchedule) {
            UserDefaults.standard.set(data, forKey: Self.claudeScheduleKey)
        }
    }

    // MARK: Lifecycle

    func start() {
        guard activityLoop == nil else { return }

        activityLoop = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refreshActivity()
                try? await Task.sleep(for: .seconds(self?.activityInterval ?? 5))
            }
        }

        limitsLoop = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refreshLimits()
                try? await Task.sleep(for: .seconds(self?.limitsInterval ?? 60))
            }
        }
    }

    func stop() {
        activityLoop?.cancel()
        limitsLoop?.cancel()
        activityLoop = nil
        limitsLoop = nil
    }

    // MARK: Refresh

    /// Re-reads the user defaults so settings changes apply without a restart.
    func reloadPreferences() {
        preferences = Preferences.load()
    }

    func refreshActivity() async {
        let current = Preferences.load()
        preferences = current
        let now = Date()
        let window = current.activityWindow

        let collected = await Task.detached(priority: .utility) {
            ActivityAggregator.collect(within: window, now: now)
        }.value

        sessions = collected
        lastRefresh = Date()
    }

    func refreshLimits() async {
        let current = Preferences.load()
        preferences = current

        let now = Date()
        let claudeDue = now >= claudeSchedule.nextFetch
        let retryText = claudeSchedule.nextFetch.formatted(date: .omitted, time: .shortened)
        let heldClaude = usages.first { $0.id == .claude }
            ?? ProviderUsage(id: .claude, error: "API 制限中（\(retryText) に再試行）")

        let collected = await Task.detached(priority: .utility) { () -> [ProviderUsage] in
            async let claude: ProviderUsage = claudeDue ? await ClaudeUsage.fetch() : heldClaude
            async let codex = CodexUsage.fetch()
            async let opencode = OpenCodeGoUsage.fetch(limits: current.openCodeLimits)
            return [await claude, await codex, await opencode]
        }.value

        // A failed refresh keeps the last good numbers instead of blanking the card.
        let previous = Dictionary(uniqueKeysWithValues: usages.map { ($0.id, $0) })
        let merged = collected.map { fresh -> ProviderUsage in
            guard let error = fresh.error, fresh.windows.isEmpty,
                  let last = previous[fresh.id], !last.windows.isEmpty
            else { return fresh }
            var kept = last
            kept.error = nil
            kept.footnote = "更新失敗: \(error)（前回の値を表示中）"
            return kept
        }
        if claudeDue, let claude = collected.first(where: { $0.id == .claude }) {
            if !claude.windows.isEmpty {
                claudeSchedule = ClaudeSchedule(
                    windows: claude.windows, asOf: claude.asOf,
                    nextFetch: now.addingTimeInterval(claudeInterval), backoff: 0
                )
            } else if claude.error?.contains("429") == true {
                claudeSchedule.backoff = min(max(claudeSchedule.backoff * 2, claudeInterval), claudeMaxBackoff)
                claudeSchedule.nextFetch = now.addingTimeInterval(claudeSchedule.backoff)
            } else {
                claudeSchedule.nextFetch = now.addingTimeInterval(claudeInterval)
            }
            saveClaudeSchedule()
        }
        usages = mergedClaudeNote(merged).sorted { lhs, rhs in
            let left = ProviderKind.allCases.firstIndex(of: lhs.id) ?? 0
            let right = ProviderKind.allCases.firstIndex(of: rhs.id) ?? 0
            return left < right
        }
    }

    /// While backing off after a 429, say so (and when it retries) under the held numbers.
    private func mergedClaudeNote(_ usages: [ProviderUsage]) -> [ProviderUsage] {
        guard claudeSchedule.backoff > 0 else { return usages }
        let retry = claudeSchedule.nextFetch.formatted(date: .omitted, time: .shortened)
        return usages.map { usage in
            guard usage.id == .claude, !usage.windows.isEmpty else { return usage }
            var held = usage
            held.footnote = "API 制限中のため前回の値を表示（\(retry) に再試行）"
            return held
        }
    }

    func refreshNow() {
        guard !isRefreshing else { return }
        isRefreshing = true
        Task {
            async let activity: Void = refreshActivity()
            async let limits: Void = refreshLimits()
            _ = await (activity, limits)
            isRefreshing = false
        }
    }

    // MARK: Derived state

    var visibleUsages: [ProviderUsage] {
        usages.filter { preferences.visibleProviders.contains($0.id) }
    }

    /// Agents doing something right now (idle IDE/app helpers and quiet logs excluded).
    var workingSessions: [AgentSession] {
        let now = Date()
        return sessions.filter { $0.isWorking(now: now) }
    }

    /// Working agents per tool, in a fixed tool order, for the menu bar.
    var workingByTool: [(tool: AgentTool, count: Int)] {
        let working = workingSessions
        return AgentTool.allCases.compactMap { tool in
            let count = working.filter { $0.tool == tool }.count
            return count > 0 ? (tool, count) : nil
        }
    }






    var lastRefreshText: String {
        guard let lastRefresh else { return "—" }
        return "updated " + DurationText.elapsed(since: lastRefresh)
    }
}
