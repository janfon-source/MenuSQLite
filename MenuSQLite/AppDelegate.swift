import AppKit
import ServiceManagement

/// Menu bar app: no Dock icon, just a status item that toggles a popover.
@main
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    // NSApplication holds its delegate weakly, so keep it alive here.
    private static var instance: AppDelegate?

    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        instance = delegate
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }

    private var statusItem: NSStatusItem!
    private let popover = NSPopover()
    private let main = MainViewController()
    /// Holds the content while it's pinned. Made the first time it's needed.
    private var panel: NSPanel?
    private static let panelFrameName = "MenuSQLitePinnedWindow"

    func applicationDidFinishLaunching(_ notification: Notification) {
        popover.contentViewController = main
        main.popover = popover
        main.applyPopoverBehavior()
        main.onPinChange = { [weak self] pinned in pinned ? self?.pin() : self?.unpin() }
        Theme.apply(to: popover)

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "cylinder.split.1x2", accessibilityDescription: nil)
            button.image?.isTemplate = true
            button.target = self
            button.action = #selector(statusItemClicked(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }

        applyLanguage()
        NotificationCenter.default.addObserver(forName: Language.didChange, object: nil, queue: .main) { [weak self] _ in
            self?.applyLanguage()
        }
        main.reopenLast()

        // Opened by hand: show the window so people see where it lives.
        // Started at login: stay quietly in the menu bar.
        if SMAppService.mainApp.status != .enabled {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { self.showPopover() }
        }
    }

    private func applyLanguage() {
        NSApp.mainMenu = MainMenu.build(main: main)
        statusItem.button?.toolTip = tr("隨手庫", "MenuSQLite")
        statusItem.button?.setAccessibilityLabel(tr("隨手庫", "MenuSQLite"))
    }

    @objc private func statusItemClicked(_ sender: NSStatusBarButton) {
        if NSApp.currentEvent?.type == .rightMouseUp {
            showStatusMenu()
        } else if main.pinned {
            panel?.isVisible == true ? panel?.orderOut(nil) : showPopover()
        } else {
            popover.isShown ? popover.performClose(nil) : showPopover()
        }
    }

    func showPopover() {
        if main.pinned { return showPanel() }
        guard let button = statusItem.button, !popover.isShown else { return }
        NSApp.activate(ignoringOtherApps: true)
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        main.focus()
    }

    // MARK: Pinned window

    /// Moves the content out of the popover into a window of its own, at the same place and size,
    /// which can then be dragged anywhere and stays up when other apps are used.
    private func pin() {
        var rect: NSRect?
        if popover.isShown, let window = main.view.window {
            rect = window.convertToScreen(main.view.convert(main.view.bounds, to: nil))
            popover.animates = false
            popover.close()
            popover.animates = true
        }
        let panel = self.panel ?? makePanel()
        self.panel = panel
        // Where the popover was, or else where the window was left. The view goes in as the content
        // view, not as a content view controller, whose preferred size the window would keep to
        // and so refuse to be resized.
        let frame = rect.map { panel.frameRect(forContentRect: $0) } ?? panel.frame
        popover.contentViewController = nil
        panel.contentView = main.view
        main.preferredContentSize = panel.contentRect(forFrameRect: frame).size
        panel.setFrame(frame, display: false)
        main.pinnedWindow = panel
        if rect != nil { showPanel() }
    }

    /// Puts the content back in the popover under the menu bar icon, at the size it had before.
    private func unpin() {
        let wasShowing = panel?.isVisible ?? false
        panel?.orderOut(nil)
        panel?.contentView = NSView()
        main.pinnedWindow = nil
        popover.contentViewController = main
        main.restorePopoverSize()
        if wasShowing { showPopover() }
    }

    private func showPanel() {
        if panel == nil || main.pinnedWindow == nil { pin() }
        guard let panel else { return }
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        main.focus()
    }

    /// A window that looks much like the popover: no title bar to speak of, dragged by its top edge
    /// or any empty background, and floating above other apps' windows as the popover did.
    private func makePanel() -> NSPanel {
        let panel = NSPanel(contentRect: NSRect(origin: .zero, size: main.view.frame.size),
                            styleMask: [.titled, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        for button in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            panel.standardWindowButton(button)?.isHidden = true
        }
        panel.isMovableByWindowBackground = true
        panel.delegate = self
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.level = .floating
        panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        panel.minSize = panel.frameRect(forContentRect: NSRect(origin: .zero, size: MainViewController.minSize)).size
        // Where it was left last time; the first time, just under the menu bar icon.
        if !panel.setFrameUsingName(Self.panelFrameName), let button = statusItem.button?.window?.frame {
            let size = panel.frame.size
            panel.setFrameOrigin(NSPoint(x: button.midX - size.width / 2, y: button.minY - size.height - 6))
        }
        panel.setFrameAutosaveName(Self.panelFrameName)
        return panel
    }

    /// The popover left a constraint holding the view to the controller's preferred size, which
    /// would pull the window back; it follows the window's size instead while pinned.
    func windowDidResize(_ notification: Notification) {
        guard let panel, notification.object as? NSPanel === panel, main.pinnedWindow === panel else { return }
        main.preferredContentSize = panel.contentRect(forFrameRect: panel.frame).size
    }

    private func showStatusMenu() {
        let menu = NSMenu()
        menu.addItem(withTitle: tr("開啟隨手庫", "Open MenuSQLite"), action: #selector(openFromMenu), keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: tr("結束隨手庫", "Quit MenuSQLite"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }

    @objc private func openFromMenu() { showPopover() }

    /// Databases opened from Finder (Open With, or dropped on the app icon).
    func application(_ application: NSApplication, open urls: [URL]) {
        guard let url = urls.first else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            self.showPopover()
            self.main.open(url)
        }
    }
}
