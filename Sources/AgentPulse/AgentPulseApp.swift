import AppKit
import Combine
import SwiftUI
import AgentPulseCore

/// Plain AppKit entry point. The status item, popover and settings window are owned by
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
        AppModel.shared.start()
        statusBar = StatusBarController(model: .shared)
    }

    /// `AgentPulse --snapshot out.png` renders the popover with live data and exits,
    /// so the UI can be checked without opening the menu bar.
    private var snapshotPath: String? {
        let arguments = CommandLine.arguments
        guard let index = arguments.firstIndex(of: "--snapshot"), index + 1 < arguments.count else { return nil }
        return arguments[index + 1]
    }

    private func writeSnapshot(to path: String) async {
        GlassRendering.plain = true
        let model = AppModel.shared
        await model.refreshActivity()
        await model.refreshLimits()
        // ImageRenderer cannot draw ScrollView, buttons or glass, so render the torn-off section
        // views (glass painted plain) on a desktop-like backdrop, under the menu-bar title.
        let menuBar = HStack(spacing: 0) {
            Image(systemName: "waveform.path.ecg")
            Text(AttributedString(StatusBarController.menuBarTitle(for: model)))
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 5))
        let cards = VStack(alignment: .leading, spacing: 0) {
            menuBar.padding(14)
            SectionWindowView(section: .limits)
            SectionWindowView(section: .running)
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

    /// Clicking the Dock (or Launchpad) icon while running opens the popover.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        statusBar?.showPopover()
        return false
    }
}

/// Menu-bar item (icon + `2 · 88%`) that toggles the popover.
@MainActor
final class StatusBarController: NSObject {
    private let model: AppModel
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let popover = NSPopover()
    private var settingsWindow: NSWindow?
    private var sectionWindows: [PanelSection: NSPanel] = [:]
    private var subscription: AnyCancellable?

    init(model: AppModel) {
        self.model = model
        super.init()

        // Stays open while other apps are used; only the menu-bar icon, × or Esc close it.
        popover.behavior = .applicationDefined
        popover.animates = false
        // Dragging the popover tears it off the menu bar into a window that can be moved anywhere.
        popover.delegate = self
        popover.contentViewController = NSHostingController(
            rootView: PopoverView(
                openSettings: { [weak self] in self?.showSettings() },
                close: { [weak self] in self?.closePopover() },
                tearOff: { [weak self] in self?.dragSection($0) }
            )
            .environmentObject(model)
        )

        if let button = statusItem.button {
            button.imagePosition = .imageLeading
            button.target = self
            button.action = #selector(togglePopover)
        }
        updateButton()
        // `objectWillChange` fires before the change lands, so read the new values on the next turn.
        subscription = model.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.updateButton() }
    }

    var isPopoverShown: Bool { popover.isShown }

    func showPopover() {
        guard let button = statusItem.button, !popover.isShown else { return }
        NSApp.activate()
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        keepOnTop()
        popover.contentViewController?.view.window?.makeKey()
    }

    /// Keep the popover (attached or torn off) above other apps' windows and on every Space.
    private func keepOnTop() {
        guard let window = popover.contentViewController?.view.window else { return }
        window.level = .floating
        window.hidesOnDeactivate = false
        window.collectionBehavior.formUnion([.canJoinAllSpaces, .fullScreenAuxiliary])
    }

    func closePopover() {
        popover.performClose(nil)
    }

    /// Follows a section-header drag: once the cursor leaves the popover, that section's own
    /// small window appears under the cursor and moves with it; where the drag ends, it stays.
    func dragSection(_ section: PanelSection) {
        let mouse = NSEvent.mouseLocation
        let existing = sectionWindows[section]
        if existing?.isVisible != true,
           popover.contentViewController?.view.window?.frame.contains(mouse) == true {
            return
        }
        let window = existing ?? makeSectionWindow(section)
        window.setFrameTopLeftPoint(NSPoint(x: mouse.x - 60, y: mouse.y + 12))
        if !window.isVisible { window.orderFrontRegardless() }
    }

    private func makeSectionWindow(_ section: PanelSection) -> NSPanel {
        // No frame or background of its own: only the SwiftUI glass shapes show.
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 200),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        let host = NSHostingController(
            rootView: SectionWindowView(section: section, close: { [weak panel] in panel?.orderOut(nil) })
                .environmentObject(model)
        )
        host.sizingOptions = [.preferredContentSize]
        host.view.wantsLayer = true
        host.view.layer?.backgroundColor = .clear
        panel.contentViewController = host
        panel.title = section.title
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.isMovableByWindowBackground = true
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.collectionBehavior.formUnion([.canJoinAllSpaces, .fullScreenAuxiliary])
        sectionWindows[section] = panel
        return panel
    }

    @objc private func togglePopover() {
        if popover.isShown {
            closePopover()
        } else {
            showPopover()
        }
    }

    private func showSettings() {
        popover.performClose(nil)
        if settingsWindow == nil {
            let window = NSWindow(contentViewController: NSHostingController(
                rootView: SettingsView().environmentObject(model)
            ))
            window.title = "AgentPulse 設定"
            window.styleMask = [.titled, .closable]
            window.isReleasedWhenClosed = false
            window.center()
            settingsWindow = window
        }
        NSApp.activate()
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    private func updateButton() {
        guard let button = statusItem.button else { return }
        let image = NSImage(systemSymbolName: "waveform.path.ecg", accessibilityDescription: "AgentPulse")
        image?.isTemplate = true
        button.image = image
        button.attributedTitle = Self.menuBarTitle(for: model)
        button.toolTip = Self.menuBarToolTip(for: model)
    }

    /// ` ● Claude ×2  ● DSH`: the agents working right now, in their badge colours.
    /// Usage stays in the popover so the menu bar only answers "what is running".
    /// Hovering the icon lists each working agent: `Claude · AgentPulse — Bash: swift build`.
    static func menuBarToolTip(for model: AppModel) -> String {
        let working = model.workingSessions
        guard !working.isEmpty else { return "実行中のエージェントはありません" }
        return working
            .map { "\($0.tool.displayName) · \($0.directoryName) — \($0.summary)" }
            .joined(separator: "\n")
    }

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

extension StatusBarController: NSPopoverDelegate {
    func popoverShouldDetach(_ popover: NSPopover) -> Bool { true }

    func popoverDidDetach(_ popover: NSPopover) {
        keepOnTop()
    }
}
