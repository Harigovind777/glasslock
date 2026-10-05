import AppKit
import GlassLockCore

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate(options: LaunchOptions.parse(CommandLine.arguments))
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
}
