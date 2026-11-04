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

/// The appearance settings, shared by every window. `@AppStorage` keys with dots in them
/// (`appearance.glassStyle`) are not observed across views, so a change made in the settings
/// window never reached the open panels; one published object updates them all at once.
@MainActor
final class Appearance: ObservableObject {
    static let shared = Appearance()
    private let defaults = UserDefaults.standard

    @Published var style: String { didSet { defaults.set(style, forKey: SettingsKey.glassStyle) } }
    @Published var transparency: Double { didSet { defaults.set(transparency, forKey: SettingsKey.glassTransparency) } }
    @Published var density: Double { didSet { defaults.set(density, forKey: SettingsKey.glassDensity) } }

    private init() {
        SettingsKey.register(in: defaults)
        style = defaults.string(forKey: SettingsKey.glassStyle) ?? "clear"
        transparency = defaults.double(forKey: SettingsKey.glassTransparency)
        density = defaults.double(forKey: SettingsKey.glassDensity)
    }
}

/// The glass behind a card, following the appearance settings. The glass is its own layer
/// under the content, so it can be faded toward fully see-through without fading the text;
/// a thin light rim keeps the edge reading as glass even when the layer is faint.
struct GlassSurface: ViewModifier {
    let cornerRadius: CGFloat
    @ObservedObject private var appearance = Appearance.shared

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        if GlassRendering.plain {
            content.background(Color.white.opacity(0.75), in: shape)
        } else {
            content
                .background(Color(nsColor: .windowBackgroundColor).opacity(appearance.density), in: shape)
                .background { glass(in: shape).opacity(1 - appearance.transparency * 0.9) }
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
            Color.clear.glassEffect(appearance.style == "clear" ? .clear : .regular, in: shape)
        } else if appearance.style == "clear" {
            shape.fill(.ultraThinMaterial)
        } else {
            shape.fill(.regularMaterial)
        }
    }
}
