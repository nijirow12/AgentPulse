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

/// The glass behind a card, following the appearance settings: the glass variant, and how
/// much solid backing is laid over it (more backing reads better on busy wallpapers).
struct GlassSurface: ViewModifier {
    let cornerRadius: CGFloat
    @AppStorage(SettingsKey.glassStyle) private var style = "regular"
    @AppStorage(SettingsKey.glassDensity) private var density = 0.0

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        let backed = content.background(Color(nsColor: .windowBackgroundColor).opacity(density), in: shape)
        if GlassRendering.plain {
            content.background(Color.white.opacity(0.75), in: shape)
        } else if #available(macOS 26.0, *) {
            backed.glassEffect(style == "clear" ? .clear : .regular, in: shape)
        } else if style == "clear" {
            backed.background(.ultraThinMaterial, in: shape)
        } else {
            backed.background(.regularMaterial, in: shape)
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
