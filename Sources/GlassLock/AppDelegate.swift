import AppKit
import GlassLockCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let options: LaunchOptions
    private let controller: AppController
    private var menu: MenuBarController!
    let topicStore = TopicStore(directory: AppPaths.supportDirectory)
    var relay: RelayClient?

    init(options: LaunchOptions) {
        self.options = options
        self.controller = AppController(devAutoUnlockSeconds: options.autoUnlockSeconds)
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        Log.write("launched\(options.isDevMode ? " (developer mode)" : "")")
        menu = MenuBarController(devMode: options.isDevMode)
        menu.onLockNow = { [weak self] in self?.controller.handle(.lockRequested(.local)) }
        menu.insertItem("Install iPhone Shortcut…", action: #selector(installShortcut), target: self)
        menu.insertItem("Reset Secret…", action: #selector(resetSecret), target: self)
        startRelay()
        controller.start()
        if options.lockOnLaunch {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
                self?.controller.handle(.lockRequested(.local))
            }
        }
    }

    private func startRelay() {
        let topic: String
        do {
            topic = try topicStore.loadOrCreate()
        } catch {
            Log.write("could not load or create topic: \(error)")
            menu.setStatus("Setup error — see log", connected: false)
            return
        }
        let relay = RelayClient(topic: topic)
        relay.onStatus = { [weak self] status in
            let (text, connected) = Self.describe(status)
            self?.menu.setStatus(text, connected: connected)
        }
        relay.onLock = { [weak self] id in
            self?.controller.handle(.lockRequested(.remote(commandID: id)))
        }
        controller.onAck = { [weak relay] kind, id in
            relay?.sendAck(kind, commandID: id)
        }
        relay.start()
        self.relay = relay
    }

    @objc private func installShortcut() {
        guard let topic = try? topicStore.loadOrCreate() else { return }
        NSApp.activate(ignoringOtherApps: true)
        do {
            let file = try ShortcutInstaller.install(topic: topic)
            Log.write("shortcut signed and opened")
            let alert = NSAlert()
            alert.messageText = "Add the “Lock Mac” Shortcut"
            alert.informativeText = """
                Shortcuts is opening — click “Add Shortcut”. It syncs to your iPhone through iCloud \
                (iPhone Settings › Apps › Shortcuts › iCloud Sync). You can also AirDrop the file to your iPhone.
                """
            alert.addButton(withTitle: "OK")
            alert.addButton(withTitle: "Show File for AirDrop")
            if alert.runModal() == .alertSecondButtonReturn {
                NSWorkspace.shared.activateFileViewerSelecting([file])
            }
        } catch {
            Log.write("shortcut install failed: \(error)")
            showManualInstructions(topic: topic)
        }
    }

    private func showManualInstructions(topic: String) {
        let alert = NSAlert()
        alert.messageText = "Set up the Shortcut by hand"
        alert.informativeText = ShortcutBuilder.manualInstructions(topic: topic)
        alert.addButton(withTitle: "Copy Instructions")
        alert.addButton(withTitle: "Close")
        if alert.runModal() == .alertFirstButtonReturn {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(alert.informativeText, forType: .string)
        }
    }

    @objc private func resetSecret() {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Reset the secret?"
        alert.informativeText = "Your current iPhone Shortcut will stop working. You'll install a new one next."
        alert.addButton(withTitle: "Reset")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        do {
            let topic = try topicStore.reset()
            relay?.change(topic: topic)
            Log.write("secret reset")
            installShortcut()
        } catch {
            Log.write("secret reset failed: \(error)")
        }
    }

    private static func describe(_ status: RelayClient.Status) -> (String, Bool) {
        switch status {
        case .connecting: return ("Connecting to relay…", false)
        case .connected: return ("Ready — lock from your iPhone", true)
        case .waiting(let seconds): return ("Offline — retrying in \(seconds)s", false)
        }
    }

    /// Refuse to quit (logout, AppleScript, …) while the glass lock is up.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if case .glassLocked = controller.state {
            Log.write("quit refused while glass-locked")
            return .terminateCancel
        }
        Log.write("quitting")
        return .terminateNow
    }
}
