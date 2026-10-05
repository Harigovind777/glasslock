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
