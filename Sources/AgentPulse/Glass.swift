import SwiftUI

/// `--snapshot` renders offscreen, where glass and materials draw nothing; it switches this on
/// to paint plain translucent shapes instead so the layout still shows.
@MainActor
enum GlassRendering {
    static var plain = false
}

/// Liquid Glass on macOS 26 and later; a translucent material on older systems.
@MainActor
extension View {
    @ViewBuilder
    func glassSurface(cornerRadius: CGFloat = 16) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        if GlassRendering.plain {
            background(Color.white.opacity(0.75), in: shape)
        } else if #available(macOS 26.0, *) {
            glassEffect(.regular, in: shape)
        } else {
            background(.ultraThinMaterial, in: shape)
        }
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
