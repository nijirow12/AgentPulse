import AppKit
import SwiftUI
import AgentPulseCore

struct SessionRow: View {
    let session: AgentSession
    @State private var isHovered = false

    private var statusColor: Color {
        if session.isProcessOnly { return session.isIdleProcess ? .gray : .green }
        let age = Date().timeIntervalSince(session.lastUpdate)
        if age <= 30 { return .green }
        if age <= 300 { return .yellow }
        return .gray
    }

    private var toolColor: Color { session.tool.color }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Circle()
                .fill(statusColor)
                .frame(width: 7, height: 7)
                .padding(.top, 5)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(session.tool.displayName)
                        .font(.system(size: 9, weight: .semibold))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(toolColor.opacity(0.18)))
                        .foregroundStyle(toolColor)

                    Text(session.directoryName)
                        .font(.caption.weight(.medium))
                        .lineLimit(1)
                        .truncationMode(.middle)

                    Spacer(minLength: 4)

                    if !session.isProcessOnly {
                        Text(DurationText.elapsed(since: session.lastUpdate))
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }

                    if let pid = session.pid {
                        Text(processText(pid: pid, cpu: session.cpu))
                            .font(.system(size: 9).monospacedDigit())
                            .foregroundStyle(.tertiary)
                    }
                }

                Text(session.summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(isHovered && session.cwd != nil ? Color.primary.opacity(0.06) : Color.clear)
        )
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
        .onTapGesture(perform: openInFinder)
        .help(session.cwd ?? "作業ディレクトリ不明")
    }

    private func processText(pid: Int32, cpu: Double?) -> String {
        guard let cpu else { return "PID \(pid)" }
        return String(format: "PID %d %.1f%%", pid, cpu)
    }

    private func openInFinder() {
        guard let cwd = session.cwd else { return }
        NSWorkspace.shared.open(URL(fileURLWithPath: cwd))
    }
}

extension AgentTool {
    /// Badge colour shared by the session rows and the menu bar.
    var color: Color {
        switch self {
        case .claude: .orange
        case .codex: .teal
        case .opencode: .indigo
        case .dsh: .purple
        }
    }
}
