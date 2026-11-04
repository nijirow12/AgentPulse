import AppKit
import SwiftUI
import AgentPulseCore

/// The main window: glass pieces floating on a transparent, frameless panel (the same look as
/// a torn-off section). Dragging the title capsule moves it.
struct MainPanelView: View {
    @EnvironmentObject private var model: AppModel
    /// Opens the settings window (owned by the status-bar controller).
    var openSettings: () -> Void = {}
    /// Closes the panel; it otherwise stays open while other apps are used.
    var close: () -> Void = {}
    /// Called while a section is dragged; tears that section off into its own window.
    var tearOff: (PanelSection) -> Void = { _ in }

    var body: some View {
        GlassGroup(spacing: 10) {
            VStack(alignment: .leading, spacing: 10) {
                header
                LimitsSection(onTearOff: { tearOff(.limits) })
                RunningSection(onTearOff: { tearOff(.running) })
                footer
            }
            .padding(14)
        }
        .frame(width: 440, alignment: .topLeading)
        .fixedSize(horizontal: false, vertical: true)
    }

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
            .glassButtonStyle()
            .buttonBorderShape(.circle)
            .disabled(model.isRefreshing)
            .help("今すぐ更新")
            Button(action: close) {
                Image(systemName: "xmark")
            }
            .glassButtonStyle()
            .buttonBorderShape(.circle)
            .keyboardShortcut(.cancelAction)
            .help("閉じる (Esc)")
        }
        .padding(.leading, 14)
        .padding(.trailing, 6)
        .padding(.vertical, 6)
        .glassSurface(cornerRadius: 22)
        .movesWindow()
    }

    private var footer: some View {
        HStack {
            Button("設定…", action: openSettings)
                .glassButtonStyle()
            Spacer()
            Button("終了") {
                NSApp.terminate(nil)
            }
            .glassButtonStyle()
        }
        .font(.callout)
    }
}

/// The two parts of the main window that can be dragged out into their own small window.
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
    var showsHeader = true

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if showsHeader {
                TearOffHeader(title: PanelSection.limits.title, onTearOff: onTearOff)
            }
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
    var showsHeader = true

    var body: some View {
        // Only agents running right now, matching the menu bar.
        let working = model.workingSessions
        VStack(alignment: .leading, spacing: 8) {
            if showsHeader {
                TearOffHeader(title: PanelSection.running.title, onTearOff: onTearOff) {
                    Text("\(working.count) 件")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Group {
                if working.isEmpty {
                    Text("実行中のエージェントはありません")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 4)
                } else if working.count > 6 {
                    // Keep the window on screen when many agents run at once.
                    ScrollView {
                        rows(working)
                    }
                    .frame(height: 300)
                } else {
                    rows(working)
                }
            }
            .padding(6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .glassSurface(cornerRadius: 16)
        }
        .tearOff(onTearOff)
    }

    private func rows(_ working: [AgentSession]) -> some View {
        VStack(spacing: 2) {
            ForEach(working) { session in
                SessionRow(session: session)
            }
        }
    }
}

/// Section title; inside the main window it shows a mark saying the section can be dragged out.
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
                    .help("この欄をドラッグしてウィンドウの外に出すと、別ウィンドウで表示します")
            }
        }
        // Floating on a transparent window, the title needs its own glass to stay readable.
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .glassSurface(cornerRadius: 16)
    }
}

extension View {
    /// Inside the main window, dragging anywhere on the section (header, cards, rows) tears it off
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

/// A torn-off section on its own: glass cards floating on a fully transparent window,
/// under a small glass title capsule that moves the window and holds the close button.
struct SectionWindowView: View {
    @EnvironmentObject private var model: AppModel
    let section: PanelSection
    var close: () -> Void = {}

    var body: some View {
        GlassGroup(spacing: 10) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Text(section.title)
                        .font(.subheadline.weight(.semibold))
                    if section == .running {
                        Text("\(model.workingSessions.count) 件")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button(action: close) {
                        Image(systemName: "xmark")
                            .font(.caption.weight(.semibold))
                    }
                    .glassButtonStyle()
                    .buttonBorderShape(.circle)
                    .help("閉じる")
                }
                .padding(.leading, 14)
                .padding(.trailing, 6)
                .padding(.vertical, 6)
                .glassSurface(cornerRadius: 20)
                .movesWindow()

                switch section {
                case .limits: LimitsSection(showsHeader: false)
                case .running: RunningSection(showsHeader: false)
                }
            }
            .padding(14)
        }
        .frame(width: 400, alignment: .topLeading)
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
