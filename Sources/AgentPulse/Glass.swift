import SwiftUI
import AgentPulseCore

/// `--snapshot` renders offscreen, where glass and materials draw nothing; it switches this on
/// to paint plain translucent shapes instead so the layout still shows.
@MainActor
enum GlassRendering {
    static var plain = false
}

/// Liquid Glass on macOS 26 and later; a translucent material on older systems.
@MainActor
extension View {
    func glassSurface(cornerRadius: CGFloat = 16) -> some View {
        modifier(GlassSurface(cornerRadius: cornerRadius))
    }

    @ViewBuilder
    func glassButtonStyle() -> some View {
        if #available(macOS 26.0, *) {
            buttonStyle(.glass)
        } else {
            buttonStyle(.borderless)
        }
    }

    /// Dragging this view moves its window (used where there is no title bar).
    @ViewBuilder
    func movesWindow() -> some View {
        if #available(macOS 15.0, *) {
            gesture(WindowDragGesture())
        } else {
            self
        }
    }
}

/// The glass behind a card, following the appearance settings. The glass is its own layer
/// under the content, so it can be faded toward fully see-through without fading the text;
/// a thin light rim keeps the edge reading as glass even when the layer is faint.
struct GlassSurface: ViewModifier {
    let cornerRadius: CGFloat
    @AppStorage(SettingsKey.glassStyle) private var style = "clear"
    @AppStorage(SettingsKey.glassTransparency) private var transparency = 0.4
    @AppStorage(SettingsKey.glassDensity) private var density = 0.0

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        if GlassRendering.plain {
            content.background(Color.white.opacity(0.75), in: shape)
        } else {
            content
                .background(Color(nsColor: .windowBackgroundColor).opacity(density), in: shape)
                .background { glass(in: shape).opacity(1 - transparency * 0.9) }
                .overlay {
                    shape.strokeBorder(
                        LinearGradient(
                            colors: [.white.opacity(0.55), .white.opacity(0.08), .white.opacity(0.25)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 1
                    )
                }
        }
    }

    @ViewBuilder
    private func glass(in shape: RoundedRectangle) -> some View {
        if #available(macOS 26.0, *) {
            Color.clear.glassEffect(style == "clear" ? .clear : .regular, in: shape)
        } else if style == "clear" {
            shape.fill(.ultraThinMaterial)
        } else {
            shape.fill(.regularMaterial)
        }
    }
}

/// Groups glass shapes so they render and blend as one layer, as Apple recommends.
struct GlassGroup<Content: View>: View {
    var spacing: CGFloat = 8
    @ViewBuilder var content: Content

    var body: some View {
        if #available(macOS 26.0, *) {
            GlassEffectContainer(spacing: spacing) { content }
        } else {
            content
        }
    }
}
