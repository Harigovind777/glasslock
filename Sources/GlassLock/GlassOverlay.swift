import AppKit

/// Borderless window that may take keyboard focus.
final class ShieldWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

/// Frosted-glass lock: one live-blurred window per screen above everything,
/// the unlock panel on the main screen, and kiosk options that block app
/// switching, Force Quit, the Dock and the menu bar.
@MainActor
final class GlassOverlay {
    /// Darkening over the blur. Raise it if text under the overlay is readable.
    static let tintAlpha: CGFloat = 0.35

    static let kioskOptions: NSApplication.PresentationOptions = [
        .hideDock, .hideMenuBar, .disableProcessSwitching, .disableForceQuit,
        .disableSessionTermination, .disableHideApplication, .disableAppleMenu,
    ]

    var onUnlocked: () -> Void = {}
    var onPasswordFailed: () -> Void = {}
    /// The screen could not be secured — the caller must fail closed.
    var onFailure: (String) -> Void = { _ in }

    private var windows: [ShieldWindow] = []
    private var panel: UnlockPanel?
    private var appObservers: [NSObjectProtocol] = []
    private var workspaceObservers: [NSObjectProtocol] = []
    private var savedOptions: NSApplication.PresentationOptions = []

    var isVisible: Bool { panel != nil }

    func show(caption: String) {
        guard !isVisible else { return }
        guard !NSScreen.screens.isEmpty else {
            onFailure("no screens")
            return
        }
        let panel = UnlockPanel(caption: caption)
        panel.onUnlocked = { [weak self] in self?.onUnlocked() }
        panel.onPasswordFailed = { [weak self] in self?.onPasswordFailed() }
        self.panel = panel

        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        layoutWindows()
        savedOptions = NSApp.presentationOptions
        NSApp.presentationOptions = Self.kioskOptions
        startGuarding()
        panel.startTouchID()
        Log.write("overlay shown on \(windows.count) screen(s)")

        // Fail closed: without keyboard focus, keystrokes would reach the apps underneath.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            guard let self, self.panel === panel else { return }
            if !NSApp.isActive || !(panel.window?.isKeyWindow ?? false) {
                self.onFailure("could not take keyboard focus")
            }
        }
    }

    func hide() {
        guard let panel else { return }
        stopGuarding()
        panel.stopTouchID()
        windows.forEach { $0.orderOut(nil) }
        windows.removeAll()
        self.panel = nil
        NSApp.presentationOptions = savedOptions
        NSApp.setActivationPolicy(.accessory)
        Log.write("overlay hidden")
    }

    func showPasswordRejected(attemptsLeft: Int) {
        panel?.showRejected(attemptsLeft: attemptsLeft)
    }

    // MARK: Windows

    /// (Re)builds one window per connected screen and puts the panel on the main one.
    private func layoutWindows() {
        guard let panel else { return }
        windows.forEach { $0.orderOut(nil) }
        windows = NSScreen.screens.map { Self.makeWindow(for: $0) }
        let mainScreen = NSScreen.main ?? NSScreen.screens[0]
        let host = windows.first(where: { $0.screen == mainScreen }) ?? windows[0]
        let content = host.contentView!
        panel.removeFromSuperview()
        panel.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(panel)
        NSLayoutConstraint.activate([
            panel.centerXAnchor.constraint(equalTo: content.centerXAnchor),
            panel.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -96),
        ])
        windows.forEach { $0.orderFrontRegardless() }
        host.makeKeyAndOrderFront(nil)
        host.makeFirstResponder(panel.passwordField)
    }

    private static func makeWindow(for screen: NSScreen) -> ShieldWindow {
        let window = ShieldWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.setFrame(screen.frame, display: false)
        window.level = NSWindow.Level(rawValue: Int(CGShieldingWindowLevel()))
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.isReleasedWhenClosed = false
        window.animationBehavior = .none

        let blur = NSVisualEffectView()
        blur.material = .fullScreenUI
        blur.blendingMode = .behindWindow
        blur.state = .active
        let tint = NSView(frame: blur.bounds)
        tint.autoresizingMask = [.width, .height]
        tint.wantsLayer = true
        tint.layer?.backgroundColor = NSColor.black.withAlphaComponent(tintAlpha).cgColor
        blur.addSubview(tint)
        window.contentView = blur
        return window
    }

    // MARK: Guarding

    private func startGuarding() {
        let center = NotificationCenter.default
        let workspace = NSWorkspace.shared.notificationCenter
        appObservers = [
            center.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.reclaimFocus() }
            },
            center.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    Log.write("screens changed; rebuilding overlay")
                    self?.layoutWindows()
                }
            },
        ]
        workspaceObservers = [
            workspace.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.reclaimFocus() }
            },
        ]
    }

    private func stopGuarding() {
        appObservers.forEach { NotificationCenter.default.removeObserver($0) }
        workspaceObservers.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) }
        appObservers.removeAll()
        workspaceObservers.removeAll()
    }

    /// Another app tried to take focus while locked: take it back.
    private func reclaimFocus() {
        guard let panel, let host = panel.window else { return }
        NSApp.activate(ignoringOtherApps: true)
        windows.forEach { $0.orderFrontRegardless() }
        host.makeKeyAndOrderFront(nil)
        host.makeFirstResponder(panel.passwordField)
    }
}
