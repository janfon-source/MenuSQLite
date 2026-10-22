import AppKit
import ServiceManagement

/// Menu bar app: no Dock icon, just a status item that toggles a popover.
@main
final class AppDelegate: NSObject, NSApplicationDelegate {
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

    func applicationDidFinishLaunching(_ notification: Notification) {
        popover.contentViewController = main
        main.popover = popover
        main.applyPopoverBehavior()
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
        } else {
            popover.isShown ? popover.performClose(nil) : showPopover()
        }
    }

    func showPopover() {
        guard let button = statusItem.button, !popover.isShown else { return }
        NSApp.activate(ignoringOtherApps: true)
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        main.focus()
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
