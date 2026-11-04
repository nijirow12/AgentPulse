import AppKit
import Combine
import SwiftUI
import AgentPulseCore

/// Plain AppKit entry point. The status item, glass panels and settings window are owned by
/// AppDelegate: `MenuBarExtra` cannot be opened from code (which the Dock icon needs), and a
/// SwiftUI `App` with only a placeholder `Settings` scene opens that empty window at launch.
@main
enum AgentPulseMain {
    static func main() {
        MainActor.assumeIsolated {
            let delegate = AppDelegate()
            let app = NSApplication.shared
            app.delegate = delegate
            app.run()
        }
    }
}

/// Keeps the app out of the Dock while it lives in the menu bar.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusBar: StatusBarController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        SettingsKey.register()
        if let path = snapshotPath {
            Task { await writeSnapshot(to: path) }
            return
        }
        if let path = argument(after: "--demo-gif") {
            Task {
                GlassRendering.plain = true
                AppModel.shared.useDemoData()
                DemoGIF.write(model: .shared, to: path)
                NSApp.terminate(nil)
            }
            return
        }
        AppModel.shared.start()
        statusBar = StatusBarController(model: .shared)
    }

    /// `AgentPulse --snapshot out.png [--demo]` renders the main panel (with live data, or
    /// made-up data for the README with `--demo`) and exits,
    /// so the UI can be checked without opening the menu bar.
    private var snapshotPath: String? { argument(after: "--snapshot") }

    private func argument(after flag: String) -> String? {
        let arguments = CommandLine.arguments
        guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count else { return nil }
        return arguments[index + 1]
    }

    private func writeSnapshot(to path: String) async {
        GlassRendering.plain = true
        let model = AppModel.shared
        if CommandLine.arguments.contains("--demo") {
            model.useDemoData()
        } else {
            await model.refreshActivity()
            await model.refreshLimits()
        }
        // ImageRenderer cannot draw buttons or glass, so glass is painted plain; the panel sits
        // on a desktop-like backdrop under the menu-bar title, with a torn-off section beside it.
        let menuBar = HStack(spacing: 0) {
            Image(systemName: "waveform.path.ecg")
            Text(AttributedString(StatusBarController.menuBarTitle(for: model)))
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 5))
        let cards = VStack(alignment: .leading, spacing: 0) {
            menuBar.padding(14)
            MainPanelView()
        }
        .environmentObject(model)
        .background(LinearGradient(colors: [.indigo.opacity(0.5), .teal.opacity(0.4)], startPoint: .topLeading, endPoint: .bottomTrailing))
        let renderer = ImageRenderer(content: cards)
        renderer.scale = 2
        if let image = renderer.nsImage,
           let tiff = image.tiffRepresentation,
           let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
            try? png.write(to: URL(fileURLWithPath: path))
        }
        NSApp.terminate(nil)
    }

    func applicationWillTerminate(_ notification: Notification) {
        AppModel.shared.stop()
    }

    /// Clicking the Dock (or Launchpad) icon while running opens the main panel.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        statusBar?.showPanel()
        return false
    }
}

/// A frameless, transparent floating panel that only shows its SwiftUI glass shapes.
/// It can become key so Esc and keyboard shortcuts reach it.
final class GlassPanel: NSPanel {
    override var canBecomeKey: Bool { true }

    init(width: CGFloat) {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: width, height: 200),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        isMovableByWindowBackground = true
        isFloatingPanel = true
        // Above other apps' windows and on every Space, until closed.
        level = .floating
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        collectionBehavior.formUnion([.canJoinAllSpaces, .fullScreenAuxiliary])
        // In the background, Liquid Glass switches to an inactive texture: its vibrant layer is
        // hidden (dark) and the backdrop stops sampling past its edges (flat, fogged). These
        // panels float over whatever app is in front, so the glass keeps its active texture:
        // recorded while the app is active, re-applied while it is not.
        let center = NotificationCenter.default
        center.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.holdActiveLook() }
        }
        center.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.recordActiveLook() }
        }
        if NSApp.isActive { recordActiveLook() } else { holdActiveLook() }
        // A drag can leave the window between pixels, which softens its text; snap it back.
        NotificationCenter.default.addObserver(
            forName: NSWindow.didMoveNotification, object: self, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let aligned = self.frame.origin.pixelAligned
                if aligned != self.frame.origin { self.setFrameOrigin(aligned) }
            }
        }
    }

    /// What a glass layer looks like while the app is active.
    private struct LayerLook {
        var opacity: Float
        var marginWidth: Any?
        var filters: [Any]?
    }

    private var activeLooks: [ObjectIdentifier: LayerLook] = [:]
    private var lookTimer: Timer?

    /// While active: note each glass layer's look every 2 s (cards come and go with refreshes).
    private func recordActiveLook() {
        restartLookTimer(every: 2) { $0.captureLook() }
    }

    /// While inactive: put the recorded look back every second, since SwiftUI re-applies the
    /// inactive texture when it rebuilds layers.
    private func holdActiveLook() {
        restartLookTimer(every: 1) { $0.applyLook() }
    }

    private func restartLookTimer(every interval: TimeInterval, _ tick: @escaping @MainActor @Sendable (GlassPanel) -> Void) {
        lookTimer?.invalidate()
        tick(self)
        lookTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { if let self { tick(self) } }
        }
    }

    private static let marginKey = "marginWidth"

    /// The glass layers: SwiftUI draws Liquid Glass with backdrop and SDF layers. Matching on
    /// these keeps all of this a no-op if a future macOS draws glass differently.
    private func forEachGlassLayer(_ body: (CALayer) -> Void) {
        guard let root = contentView?.layer else { return }
        func walk(_ layer: CALayer) {
            let name = String(describing: type(of: layer))
            if name.contains("Backdrop") || name.contains("SDF") { body(layer) }
            layer.sublayers?.forEach(walk)
        }
        walk(root)
    }

    private func captureLook() {
        guard isVisible, NSApp.isActive else { return }
        var looks: [ObjectIdentifier: LayerLook] = [:]
        forEachGlassLayer { layer in
            looks[ObjectIdentifier(layer)] = LayerLook(
                opacity: layer.opacity,
                marginWidth: layer.responds(to: NSSelectorFromString(Self.marginKey)) ? layer.value(forKey: Self.marginKey) : nil,
                // Copies, so later in-place changes to the layer's filters do not reach the record.
                filters: layer.filters?.map { ($0 as? NSObject)?.copy() ?? $0 }
            )
        }
        activeLooks = looks
    }

    private func applyLook() {
        guard isVisible, !NSApp.isActive else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        forEachGlassLayer { layer in
            guard let look = activeLooks[ObjectIdentifier(layer)] else {
                // A layer made since the last record: at least undo the darkening.
                if layer.opacity < 1, layer.filters?.contains(where: { String(describing: $0).contains("vibrant") }) == true {
                    layer.opacity = 1
                }
                return
            }
            if layer.opacity != look.opacity { layer.opacity = look.opacity }
            if let margin = look.marginWidth,
               (layer.value(forKey: Self.marginKey) as? NSNumber) != (margin as? NSNumber) {
                layer.setValue(margin, forKey: Self.marginKey)
            }
            if let filters = look.filters {
                layer.filters = filters.map { ($0 as? NSObject)?.copy() ?? $0 }
            }
        }
        CATransaction.commit()
    }

    func host<Content: View>(_ view: Content) {
        // These panels float over other apps, so they must not take on the inactive look (the
        // glass loses its vibrant layer and turns dark) whenever another app is in front.
        let host = NSHostingController(rootView: view.environment(\.controlActiveState, .key))
        host.sizingOptions = [.preferredContentSize]
        host.view.wantsLayer = true
        host.view.layer?.backgroundColor = .clear
        contentViewController = host
    }
}

/// Menu-bar item (the running agents) that toggles the main glass panel.
@MainActor
final class StatusBarController: NSObject {
    private let model: AppModel
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let mainPanel = GlassPanel(width: 440)
    private var settingsWindow: NSWindow?
    private var sectionWindows: [PanelSection: GlassPanel] = [:]
    private var subscription: AnyCancellable?

    init(model: AppModel) {
        self.model = model
        super.init()

        mainPanel.title = "AgentPulse"
        mainPanel.host(
            MainPanelView(
                openSettings: { [weak self] in self?.showSettings() },
                close: { [weak self] in self?.closePanel() },
                tearOff: { [weak self] in self?.dragSection($0) }
            )
            .environmentObject(model)
        )

        if let button = statusItem.button {
            button.imagePosition = .imageLeading
            button.target = self
            button.action = #selector(togglePanel)
        }
        updateButton()
        // `objectWillChange` fires before the change lands, so read the new values on the next turn.
        subscription = model.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.updateButton() }
    }

    var isPanelShown: Bool { mainPanel.isVisible }

    /// Opens the main panel just under the menu-bar item (kept on screen).
    func showPanel() {
        guard !mainPanel.isVisible else { return }
        mainPanel.layoutIfNeeded()
        if let button = statusItem.button, let buttonWindow = button.window {
            let anchor = buttonWindow.convertToScreen(button.convert(button.bounds, to: nil))
            let size = mainPanel.frame.size
            let visible = (buttonWindow.screen ?? NSScreen.main)?.visibleFrame ?? .zero
            let x = min(max(anchor.midX - size.width / 2, visible.minX + 8), visible.maxX - size.width - 8)
            mainPanel.setFrameTopLeftPoint(NSPoint(x: x, y: anchor.minY - 6).pixelAligned)
        }
        NSApp.activate()
        mainPanel.makeKeyAndOrderFront(nil)
    }

    func closePanel() {
        mainPanel.orderOut(nil)
    }

    /// Follows a section drag: once the cursor leaves the main panel, that section's own small
    /// window appears under the cursor and moves with it; where the drag ends, it stays.
    func dragSection(_ section: PanelSection) {
        let mouse = NSEvent.mouseLocation
        let existing = sectionWindows[section]
        if existing?.isVisible != true, mainPanel.frame.contains(mouse) {
            return
        }
        let window = existing ?? makeSectionWindow(section)
        window.setFrameTopLeftPoint(NSPoint(x: mouse.x - 60, y: mouse.y + 12).pixelAligned)
        if !window.isVisible { window.orderFrontRegardless() }
    }

    private func makeSectionWindow(_ section: PanelSection) -> GlassPanel {
        let panel = GlassPanel(width: 400)
        panel.title = section.title
        panel.becomesKeyOnlyIfNeeded = true
        panel.host(
            SectionWindowView(section: section, close: { [weak panel] in panel?.orderOut(nil) })
                .environmentObject(model)
        )
        sectionWindows[section] = panel
        return panel
    }

    @objc private func togglePanel() {
        if mainPanel.isVisible {
            closePanel()
        } else {
            showPanel()
        }
    }

    /// Opens settings next to the main panel (which stays open) so appearance changes can be
    /// watched while they are made. It floats like the panels, so other apps do not cover it.
    private func showSettings() {
        if settingsWindow == nil {
            let host = NSHostingController(rootView: SettingsView().environmentObject(model))
            // The window decides the size; the form just fills it.
            host.sizingOptions = []
            let window = NSWindow(contentViewController: host)
            window.title = "AgentPulse 設定"
            window.styleMask = [.titled, .closable, .resizable]
            window.setContentSize(NSSize(width: 440, height: 600))
            window.contentMinSize = NSSize(width: 400, height: 360)
            window.level = .floating
            window.hidesOnDeactivate = false
            window.isReleasedWhenClosed = false
            window.collectionBehavior.formUnion([.canJoinAllSpaces, .fullScreenAuxiliary])
            settingsWindow = window
        }
        guard let window = settingsWindow else { return }
        if !window.isVisible { placeSettings(window) }
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
    }

    /// Left of the main panel, top-aligned; to its right when there is no room; else centred.
    private func placeSettings(_ window: NSWindow) {
        guard mainPanel.isVisible, let screen = mainPanel.screen?.visibleFrame else {
            window.center()
            return
        }
        let panel = mainPanel.frame
        let size = window.frame.size
        let gap: CGFloat = 12
        var x = panel.minX - gap - size.width
        if x < screen.minX + 8 { x = panel.maxX + gap }
        if x + size.width > screen.maxX - 8 {
            window.center()
            return
        }
        let top = min(panel.maxY, screen.maxY)
        window.setFrameTopLeftPoint(NSPoint(x: x, y: max(top, screen.minY + size.height)).pixelAligned)
    }

    private func updateButton() {
        guard let button = statusItem.button else { return }
        let image = NSImage(systemSymbolName: "waveform.path.ecg", accessibilityDescription: "AgentPulse")
        image?.isTemplate = true
        button.image = image
        button.attributedTitle = Self.menuBarTitle(for: model)
        button.toolTip = Self.menuBarToolTip(for: model)
    }

    /// Hovering the icon lists each working agent: `Claude · AgentPulse — Bash: swift build`.
    static func menuBarToolTip(for model: AppModel) -> String {
        let working = model.workingSessions
        guard !working.isEmpty else { return "実行中のエージェントはありません" }
        return working
            .map { "\($0.tool.displayName) · \($0.directoryName) — \($0.summary)" }
            .joined(separator: "\n")
    }

    /// ` ● Claude ×2  ● DSH`: the agents working right now, in their badge colours.
    /// Usage stays in the main panel so the menu bar only answers "what is running".
    static func menuBarTitle(for model: AppModel) -> NSAttributedString {
        let font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        let title = NSMutableAttributedString()
        let working = model.workingByTool
        for (tool, count) in working {
            title.append(NSAttributedString(
                string: " ●",
                attributes: [.font: font, .foregroundColor: NSColor(tool.color)]
            ))
            title.append(NSAttributedString(
                string: " \(tool.displayName)" + (count > 1 ? " ×\(count)" : ""),
                attributes: [.font: font, .foregroundColor: NSColor.labelColor]
            ))
        }
        return title
    }
}

extension NSPoint {
    /// Whole points. The cursor and the menu-bar item sit at fractional positions; a window
    /// placed there is drawn between pixels and its text comes out soft.
    var pixelAligned: NSPoint { NSPoint(x: x.rounded(), y: y.rounded()) }
}
