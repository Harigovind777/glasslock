import AppKit
import GlassLockCore

@MainActor
final class MenuBarController: NSObject {
    var onLockNow: () -> Void = {}

    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let statusLine = NSMenuItem(title: "Starting…", action: nil, keyEquivalent: "")
    private let menu = NSMenu()

    init(devMode: Bool) {
        super.init()
        statusLine.isEnabled = false
        menu.addItem(statusLine)
        if devMode {
            let dev = NSMenuItem(title: "Developer mode (auto-unlock on)", action: nil, keyEquivalent: "")
            dev.isEnabled = false
            menu.addItem(dev)
        }
        menu.addItem(.separator())
        menu.addItem(makeItem("Glass Lock Now", #selector(lockNow)))
        menu.addItem(makeItem("Open Log", #selector(openLog)))
        menu.addItem(.separator())
        menu.addItem(makeItem("Quit GlassLock", #selector(quit)))
        item.menu = menu
        setStatus("Starting…", connected: false)
    }

    func setStatus(_ text: String, connected: Bool) {
        statusLine.title = text
        item.button?.image = NSImage(
            systemSymbolName: connected ? "lock.fill" : "lock.slash",
            accessibilityDescription: "GlassLock")
    }

    /// Inserts an item just above "Open Log". Used by later features.
    func insertItem(_ title: String, action: Selector, target: AnyObject) {
        let newItem = NSMenuItem(title: title, action: action, keyEquivalent: "")
        newItem.target = target
        let index = menu.indexOfItem(withTitle: "Open Log")
        menu.insertItem(newItem, at: index)
    }

    private func makeItem(_ title: String, _ action: Selector) -> NSMenuItem {
        let menuItem = NSMenuItem(title: title, action: action, keyEquivalent: "")
        menuItem.target = self
        return menuItem
    }

    @objc private func lockNow() { onLockNow() }

    @objc private func openLog() {
        NSWorkspace.shared.open(AppPaths.logFile)
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}
