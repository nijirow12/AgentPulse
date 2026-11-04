import SwiftUI
import AgentPulseCore

struct SettingsView: View {
    @EnvironmentObject private var model: AppModel

    @AppStorage(SettingsKey.openCodeFiveHourLimit) private var fiveHourLimit: Double = 12
    @AppStorage(SettingsKey.openCodeWeeklyLimit) private var weeklyLimit: Double = 30
    @AppStorage(SettingsKey.openCodeMonthlyLimit) private var monthlyLimit: Double = 60

    @AppStorage(SettingsKey.showClaude) private var showClaude = true
    @AppStorage(SettingsKey.showCodex) private var showCodex = true
    @AppStorage(SettingsKey.showOpenCodeGo) private var showOpenCodeGo = true

    @AppStorage(SettingsKey.activityWindowMinutes) private var windowMinutes: Double = 10

    var body: some View {
        Form {
            Section("OpenCode Go の上限（USD）") {
                limitField("5 時間", value: $fiveHourLimit)
                limitField("7 日", value: $weeklyLimit)
                limitField("30 日", value: $monthlyLimit)
                Text("ローカル DB の記録から推定したコストと比較します。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("表示するプロバイダ") {
                Toggle("Claude", isOn: $showClaude)
                Toggle("Codex (GPT)", isOn: $showCodex)
                Toggle("OpenCode Go", isOn: $showOpenCodeGo)
            }

            Section("Activity") {
                HStack {
                    Text("除外する経過時間")
                    Spacer()
                    Stepper(
                        "\(Int(windowMinutes)) 分",
                        value: $windowMinutes,
                        in: 1...60,
                        step: 1
                    )
                    .fixedSize()
                }
                Text("最後の更新からこの時間を超えたセッションは一覧から除きます。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 420)
        .onChange(of: fiveHourLimit) { refreshLimits() }
        .onChange(of: weeklyLimit) { refreshLimits() }
        .onChange(of: monthlyLimit) { refreshLimits() }
        .onChange(of: showClaude) { model.reloadPreferences() }
        .onChange(of: showCodex) { model.reloadPreferences() }
        .onChange(of: showOpenCodeGo) { model.reloadPreferences() }
    }

    private func limitField(_ title: String, value: Binding<Double>) -> some View {
        HStack {
            Text(title)
            Spacer()
            TextField(title, value: value, format: .number.precision(.fractionLength(0...2)))
                .frame(width: 90)
                .multilineTextAlignment(.trailing)
            Text("USD")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func refreshLimits() {
        Task { await model.refreshLimits() }
    }
}
