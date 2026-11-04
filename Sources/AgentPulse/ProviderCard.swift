import AppKit
import SwiftUI
import AgentPulseCore

struct ProviderCard: View {
    let usage: ProviderUsage

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(usage.id.displayName)
                    .font(.subheadline.weight(.semibold))
                Spacer()
                if let asOf = usage.asOf {
                    Text(DurationText.elapsed(since: asOf))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .monospacedDigit()
                }
            }

            if let error = usage.error {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }

            ForEach(usage.windows) { window in
                UsageRow(window: window)
            }

            if let footnote = usage.footnote {
                Text(footnote)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassSurface(cornerRadius: 16)
    }
}

struct UsageRow: View {
    let window: UsageWindow

    private var tint: Color {
        if window.usedPercent >= 95 { return .red }
        if window.usedPercent >= 80 { return .orange }
        return .green
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 8) {
                Text(window.label)
                    .font(.caption)
                    .frame(width: 78, alignment: .leading)
                    .lineLimit(1)

                // Drawn by hand: the fill grows with usage, and ImageRenderer can draw it.
                GeometryReader { proxy in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.primary.opacity(0.1))
                        Capsule()
                            .fill(tint)
                            .frame(width: proxy.size.width * window.clampedPercent / 100)
                    }
                }
                .frame(height: 6)

                Text("使用 \(Int(window.usedPercent.rounded()))%")
                    .font(.caption.monospacedDigit())
                    .lineLimit(1)
                    .fixedSize()
                    .frame(width: 64, alignment: .trailing)

                Text(resetText)
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 58, alignment: .trailing)
                    .lineLimit(1)
            }

            if let note = window.note {
                Text(note)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .padding(.leading, 86)
                    .lineLimit(1)
            }
        }
    }

    private var resetText: String {
        guard let resetsAt = window.resetsAt else { return "" }
        return DurationText.remaining(until: resetsAt)
    }
}
