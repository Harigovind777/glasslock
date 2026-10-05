import AppKit
import GlassLockCore

// Demo: glass-lock 2 s after launch; quits on unlock or after the safety timeout.
MainActor.assumeIsolated {
    let options = LaunchOptions.parse(CommandLine.arguments)
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    let overlay = GlassOverlay()
    var attemptsLeft = 5
    overlay.onUnlocked = {
        Log.write("demo: unlocked")
        overlay.hide()
        NSApp.terminate(nil)
    }
    overlay.onPasswordFailed = {
        attemptsLeft -= 1
        overlay.showPasswordRejected(attemptsLeft: attemptsLeft)
    }
    overlay.onFailure = { reason in
        Log.write("demo: OVERLAY FAILURE — \(reason)")
        overlay.hide()
        NSApp.terminate(nil)
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
        overlay.show(caption: LockCaption.text(for: .local, time: "demo"))
    }
    let safety = options.autoUnlockSeconds ?? 30
    DispatchQueue.main.asyncAfter(deadline: .now() + .seconds(safety)) {
        Log.write("demo: safety auto-unlock after \(safety)s")
        overlay.hide()
        NSApp.terminate(nil)
    }
    app.run()
}
