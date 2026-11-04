import AppKit
import SwiftUI
import AgentPulseCore

struct PopoverView: View {
    @EnvironmentObject private var model: AppModel
    /// Opens the settings window (owned by the status-bar controller).
    var openSettings: () -> Void = {}
    /// Closes the popover; it otherwise stays open while other apps are used.
    var close: () -> Void = {}

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    limitsSection
                    activitySection
                }
                .padding(12)
            }
            .frame(maxHeight: 520)
            Divider()
            footer
        }
        .frame(width: 420)
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "waveform.path.ecg")
                .foregroundStyle(.tint)
            Text("AgentPulse")
                .font(.headline)
            Spacer()
            Text(model.lastRefreshText)
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
            Button {
                model.refreshNow()
            } label: {
                Image(systemName: "arrow.clockwise")
                    .opacity(model.isRefreshing ? 0.4 : 1)
            }
            .buttonStyle(.borderless)
            .disabled(model.isRefreshing)
            .help("今すぐ更新")
            Button(action: close) {
                Image(systemName: "xmark")
            }
            .buttonStyle(.borderless)
            .keyboardShortcut(.cancelAction)
            .help("閉じる (Esc)")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    // MARK: Limits

    private var limitsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionHeader(title: "Limits")
            if model.visibleUsages.isEmpty {
                Text("表示するプロバイダがありません（設定から有効にできます）")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(model.visibleUsages) { usage in
                    ProviderCard(usage: usage)
                }
            }
        }
    }

    // MARK: Activity

    private var activitySection: some View {
        // Only agents running right now, matching the menu bar.
        let working = model.workingSessions
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                SectionHeader(title: "実行中")
                Spacer()
                Text("\(working.count) 件")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if working.isEmpty {
                Text("実行中のエージェントはありません")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                VStack(spacing: 4) {
                    ForEach(working) { session in
                        SessionRow(session: session)
                    }
                }
            }
        }
    }

    // MARK: Footer

    private var footer: some View {
        HStack {
            Button("設定…", action: openSettings)
                .buttonStyle(.borderless)
            Spacer()
            Button("終了") {
                NSApp.terminate(nil)
            }
            .buttonStyle(.borderless)
        }
        .font(.callout)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}

struct SectionHeader: View {
    let title: String

    var body: some View {
        Text(title.uppercased())
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.secondary)
    }
}
