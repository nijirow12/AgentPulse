import Foundation

/// UserDefaults keys and the values derived from them.
public enum SettingsKey {
    public static let openCodeFiveHourLimit = "opencodeGo.fiveHourLimit"
    public static let openCodeWeeklyLimit = "opencodeGo.weeklyLimit"
    public static let openCodeMonthlyLimit = "opencodeGo.monthlyLimit"
    public static let showClaude = "provider.show.claude"
    public static let showCodex = "provider.show.codex"
    public static let showOpenCodeGo = "provider.show.opencodeGo"
    public static let activityWindowMinutes = "activity.windowMinutes"
    /// "regular" or "clear" Liquid Glass.
    public static let glassStyle = "appearance.glassStyle"
    /// 0...0.9: how much solid backing is laid over the glass (0 = most see-through).
    public static let glassDensity = "appearance.glassDensity"
    /// 0...1: how far the glass layer itself is faded out (0 = full glass, 1 = almost none).
    public static let glassTransparency = "appearance.glassTransparency"
    /// "stable" (an always-active material) or "liquid" (SwiftUI Liquid Glass).
    public static let glassRenderer = "appearance.glassRenderer"

    public static func showKey(for kind: ProviderKind) -> String {
        switch kind {
        case .claude: showClaude
        case .codex: showCodex
        case .opencodeGo: showOpenCodeGo
        }
    }

    /// Registered at launch so `@AppStorage` shows sensible values immediately.
    public static var defaults: [String: Any] {
        [
            openCodeFiveHourLimit: 12.0,
            openCodeWeeklyLimit: 30.0,
            openCodeMonthlyLimit: 60.0,
            showClaude: true,
            showCodex: true,
            showOpenCodeGo: true,
            activityWindowMinutes: 10.0,
            glassStyle: "clear",
            glassDensity: 0.0,
            glassTransparency: 0.4,
            glassRenderer: "stable",
        ]
    }

    public static func register(in userDefaults: UserDefaults = .standard) {
        userDefaults.register(defaults: defaults)
    }
}

public struct Preferences: Sendable, Equatable {
    public var openCodeLimits: OpenCodeGoUsage.Limits
    public var visibleProviders: Set<ProviderKind>
    public var activityWindow: TimeInterval

    public init(
        openCodeLimits: OpenCodeGoUsage.Limits = .init(),
        visibleProviders: Set<ProviderKind> = Set(ProviderKind.allCases),
        activityWindow: TimeInterval = 600
    ) {
        self.openCodeLimits = openCodeLimits
        self.visibleProviders = visibleProviders
        self.activityWindow = activityWindow
    }

    public static func load(from defaults: UserDefaults = .standard) -> Preferences {
        func double(_ key: String, _ fallback: Double) -> Double {
            let value = defaults.double(forKey: key)
            return value > 0 ? value : fallback
        }

        var visible: Set<ProviderKind> = []
        for kind in ProviderKind.allCases where defaults.bool(forKey: SettingsKey.showKey(for: kind)) {
            visible.insert(kind)
        }

        let minutes = double(SettingsKey.activityWindowMinutes, 10)

        return Preferences(
            openCodeLimits: OpenCodeGoUsage.Limits(
                fiveHourUSD: double(SettingsKey.openCodeFiveHourLimit, 12),
                weeklyUSD: double(SettingsKey.openCodeWeeklyLimit, 30),
                monthlyUSD: double(SettingsKey.openCodeMonthlyLimit, 60)
            ),
            visibleProviders: visible,
            activityWindow: minutes * 60
        )
    }
}
