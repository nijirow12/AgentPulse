import AppKit
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

/// `AgentPulse --demo-gif out.gif` renders, frame by frame from the real views (with made-up
/// data, see `AppModel.useDemoData`), a cursor
/// dragging the 実行中 section out of the main panel into its own window (for the README).
/// Like `--snapshot`, it renders offscreen, so glass is painted plain.
@MainActor
enum DemoGIF {
    static func write(model: AppModel, to path: String) {
        let panel = MainPanelView().environmentObject(model)
        let panelSize = ImageRenderer(content: panel).nsImage?.size ?? CGSize(width: 440, height: 600)

        let margin: CGFloat = 30
        let sectionWidth: CGFloat = 400
        let canvas = CGSize(width: margin * 3 + sectionWidth + panelSize.width, height: panelSize.height + margin * 2)
        let panelOrigin = CGPoint(x: canvas.width - margin - panelSize.width, y: margin)

        // The running section sits at the bottom of the panel, above the footer.
        let grab = CGPoint(x: panelOrigin.x + panelSize.width * 0.55, y: panelOrigin.y + panelSize.height - 120)
        let drop = CGPoint(x: margin + 60, y: margin + 40)

        var frames: [CGImage] = []
        func frame(cursor: CGPoint, tornOff: CGPoint?, pressed: Bool) {
            let view = DemoFrame(
                canvas: canvas, panelOrigin: panelOrigin,
                cursor: cursor, tornOff: tornOff, pressed: pressed
            )
            .environmentObject(model)
            let renderer = ImageRenderer(content: view)
            // 3/4 size keeps the README download small.
            renderer.scale = 0.75
            if let image = renderer.cgImage { frames.append(image) }
        }

        // 1. Rest, then the cursor moves onto the section.
        let enter = CGPoint(x: grab.x + 120, y: grab.y + 60)
        for i in 0..<8 { frame(cursor: lerp(enter, grab, ease(Double(i) / 7)), tornOff: nil, pressed: false) }
        for _ in 0..<4 { frame(cursor: grab, tornOff: nil, pressed: true) }
        // 2. Drag: once the cursor leaves the panel, the section's window follows it.
        let steps = 20
        for i in 0...steps {
            let cursor = lerp(grab, drop, ease(Double(i) / Double(steps)))
            let outside = cursor.x < panelOrigin.x
            frame(cursor: cursor, tornOff: outside ? windowOrigin(for: cursor) : nil, pressed: true)
        }
        // 3. Drop: the window stays where it was let go; the cursor moves away.
        let rest = CGPoint(x: drop.x + 160, y: drop.y + 260)
        for i in 0..<8 { frame(cursor: lerp(drop, rest, ease(Double(i) / 7)), tornOff: windowOrigin(for: drop), pressed: false) }
        for _ in 0..<12 { frame(cursor: rest, tornOff: windowOrigin(for: drop), pressed: false) }

        save(frames, to: path)
    }

    /// Where `StatusBarController.dragSection` puts the window relative to the cursor
    /// (top-left at cursor − 60, cursor + 12 in screen coordinates, i.e. 12pt above it).
    private static func windowOrigin(for cursor: CGPoint) -> CGPoint {
        CGPoint(x: cursor.x - 60, y: cursor.y - 12)
    }

    private static func lerp(_ a: CGPoint, _ b: CGPoint, _ t: Double) -> CGPoint {
        CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t)
    }

    private static func ease(_ t: Double) -> Double { t * t * (3 - 2 * t) }

    private static func save(_ frames: [CGImage], to path: String) {
        let url = URL(fileURLWithPath: path) as CFURL
        guard let destination = CGImageDestinationCreateWithURL(url, UTType.gif.identifier as CFString, frames.count, nil) else { return }
        CGImageDestinationSetProperties(destination, [
            kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0],
        ] as CFDictionary)
        let frameProperties = [
            kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 0.07],
        ] as CFDictionary
        for image in frames { CGImageDestinationAddImage(destination, image, frameProperties) }
        CGImageDestinationFinalize(destination)
    }
}

/// One frame: desktop backdrop, the main panel, the torn-off section (if any) and the cursor.
private struct DemoFrame: View {
    let canvas: CGSize
    let panelOrigin: CGPoint
    let cursor: CGPoint
    let tornOff: CGPoint?
    let pressed: Bool

    var body: some View {
        ZStack(alignment: .topLeading) {
            LinearGradient(colors: [.indigo.opacity(0.55), .teal.opacity(0.45)], startPoint: .topLeading, endPoint: .bottomTrailing)
            MainPanelView()
                .offset(x: panelOrigin.x, y: panelOrigin.y)
            if let tornOff {
                SectionWindowView(section: .running)
                    .shadow(color: .black.opacity(0.18), radius: 14, y: 6)
                    .offset(x: tornOff.x, y: tornOff.y)
            }
            Image(systemName: "cursorarrow")
                .font(.system(size: 22, weight: .regular))
                .foregroundStyle(.black)
                .shadow(color: .white, radius: 1)
                .scaleEffect(pressed ? 0.9 : 1, anchor: .topLeading)
                .offset(x: cursor.x - 4, y: cursor.y - 2)
        }
        .frame(width: canvas.width, height: canvas.height, alignment: .topLeading)
    }
}
