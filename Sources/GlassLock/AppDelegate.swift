import AppKit
import GlassLockCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let options: LaunchOptions
    private let controller: AppController
    private var menu: MenuBarController!

    init(options: LaunchOptions) {
        self.options = options
        self.controller = AppController(devAutoUnlockSeconds: options.autoUnlockSeconds)
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        Log.write("launched\(options.isDevMode ? " (developer mode)" : "")")
        menu = MenuBarController(devMode: options.isDevMode)
        menu.onLockNow = { [weak self] in self?.controller.handle(.lockRequested(.local)) }
        menu.setStatus("Relay not connected", connected: false)
        controller.start()
        if options.lockOnLaunch {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
                self?.controller.handle(.lockRequested(.local))
            }
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
