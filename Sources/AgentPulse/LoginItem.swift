import Foundation
import ServiceManagement
import AgentPulseCore

/// "Open at login", through the system's login items (`SMAppService.mainApp`).
/// The preference is kept too, so launch can re-register the app if it was moved or replaced.
@MainActor
final class LoginItem: ObservableObject {
    static let shared = LoginItem()

    @Published private(set) var isEnabled = false
    /// Registered, but the user still has to allow it in System Settings → Login Items.
    @Published private(set) var needsApproval = false
    @Published private(set) var lastError: String?

    private let defaults = UserDefaults.standard

    private init() {
        refresh()
    }

    func refresh() {
        let status = SMAppService.mainApp.status
        isEnabled = status == .enabled
        needsApproval = status == .requiresApproval
    }

    func set(_ enabled: Bool) {
        defaults.set(enabled, forKey: SettingsKey.launchAtLogin)
        apply(enabled)
    }

    /// At launch: bring the system's login items in line with the saved preference.
    func syncWithPreference() {
        let wanted = defaults.bool(forKey: SettingsKey.launchAtLogin)
        let status = SMAppService.mainApp.status
        if wanted, status != .enabled, status != .requiresApproval {
            apply(true)
        } else if !wanted, status == .enabled {
            apply(false)
        } else {
            refresh()
        }
    }

    func openSystemSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }

    private func apply(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            lastError = nil
        } catch {
            lastError = "ログイン項目を変更できませんでした（\(error.localizedDescription)）"
        }
        refresh()
    }
}
