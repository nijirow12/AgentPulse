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

    @ObservedObject private var appearance = Appearance.shared

    var body: some View {
        Form {
            Section("外観") {
                Picker("描画方式", selection: $appearance.renderer) {
                    Text("安定").tag("stable")
                    Text("Liquid Glass").tag("liquid")
                }
                .pickerStyle(.segmented)
                Text(appearance.renderer == "stable"
                     ? "どのアプリを操作していても質感が変わらない、すりガラスで表示します。"
                     : "macOS の Liquid Glass で表示します。縁の屈折が出ますが、ほかのアプリを操作している間は macOS によって曇った見た目になります。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Picker("ガラスの種類", selection: $appearance.style) {
                    Text("標準").tag("regular")
                    Text("透明").tag("clear")
                }
                .pickerStyle(.segmented)
                percentSlider("透明度", value: $appearance.transparency, in: 0...1)
                percentSlider("下地の濃さ", value: $appearance.density, in: 0...0.9)
                Text("「透明度」を上げるとガラスそのものが薄くなり、背景がよく透けます。文字が読みにくいときは「下地の濃さ」を上げてください。変更はすぐ反映されます。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

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
        // A grouped Form scrolls and has no height of its own: give it a minimum (without one
        // the window opened as a bare title bar) and let it fill the window when resized.
        .frame(minWidth: 400, maxWidth: .infinity, minHeight: 360, maxHeight: .infinity)
        .onChange(of: fiveHourLimit) { refreshLimits() }
        .onChange(of: weeklyLimit) { refreshLimits() }
        .onChange(of: monthlyLimit) { refreshLimits() }
        .onChange(of: showClaude) { model.reloadPreferences() }
        .onChange(of: showCodex) { model.reloadPreferences() }
        .onChange(of: showOpenCodeGo) { model.reloadPreferences() }
    }

    private func percentSlider(_ title: String, value: Binding<Double>, in range: ClosedRange<Double>) -> some View {
        HStack {
            Text(title)
            Slider(value: value, in: range)
            Text("\(Int((value.wrappedValue * 100).rounded()))%")
                .monospacedDigit()
                .frame(width: 40, alignment: .trailing)
        }
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
