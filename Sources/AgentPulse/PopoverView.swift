import AppKit
import SwiftUI
import AgentPulseCore

struct PopoverView: View {
    @EnvironmentObject private var model: AppModel
    /// Opens the settings window (owned by the status-bar controller).
    var openSettings: () -> Void = {}
    /// Closes the popover; it otherwise stays open while other apps are used.
    var close: () -> Void = {}
    /// Called while a section header is dragged; tears that section off into its own window.
    var tearOff: (PanelSection) -> Void = { _ in }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    LimitsSection(onTearOff: { tearOff(.limits) })
                    RunningSection(onTearOff: { tearOff(.running) })
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

/// The two parts of the popover that can be dragged out into their own small window.
enum PanelSection: String, CaseIterable {
    case limits
    case running

    var title: String {
        switch self {
        case .limits: "Limits"
        case .running: "実行中"
        }
    }
}

struct LimitsSection: View {
    @EnvironmentObject private var model: AppModel
    /// nil when the section already is its own window.
    var onTearOff: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            TearOffHeader(title: PanelSection.limits.title, onTearOff: onTearOff)
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
        .tearOff(onTearOff)
    }
}

struct RunningSection: View {
    @EnvironmentObject private var model: AppModel
    /// nil when the section already is its own window.
    var onTearOff: (() -> Void)?

    var body: some View {
        // Only agents running right now, matching the menu bar.
        let working = model.workingSessions
        VStack(alignment: .leading, spacing: 8) {
            TearOffHeader(title: PanelSection.running.title, onTearOff: onTearOff) {
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
        .tearOff(onTearOff)
    }
}

/// Section title; inside the popover it shows a mark saying the section can be dragged out.
struct TearOffHeader<Trailing: View>: View {
    let title: String
    let onTearOff: (() -> Void)?
    @ViewBuilder var trailing: Trailing

    init(title: String, onTearOff: (() -> Void)?, @ViewBuilder trailing: () -> Trailing = { EmptyView() }) {
        self.title = title
        self.onTearOff = onTearOff
        self.trailing = trailing()
    }

    var body: some View {
        HStack(spacing: 6) {
            SectionHeader(title: title)
            Spacer()
            trailing
            if onTearOff != nil {
                Image(systemName: "rectangle.portrait.on.rectangle.portrait")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .help("この欄をドラッグしてパネルの外に出すと、別ウィンドウで表示します")
            }
        }
    }
}

extension View {
    /// Inside the popover, dragging anywhere on the section (header, cards, rows) tears it off
    /// into its own window. Clicks still reach the rows, since a drag needs 6pt of movement.
    @ViewBuilder
    func tearOff(_ onTearOff: (() -> Void)?) -> some View {
        if let onTearOff {
            contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 6).onChanged { _ in onTearOff() })
        } else {
            self
        }
    }
}

/// A torn-off section on its own: the content of a small floating window.
struct SectionWindowView: View {
    let section: PanelSection

    var body: some View {
        Group {
            switch section {
            case .limits: LimitsSection()
            case .running: RunningSection()
            }
        }
        .padding(12)
        .frame(width: 380, alignment: .topLeading)
        .fixedSize(horizontal: false, vertical: true)
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
