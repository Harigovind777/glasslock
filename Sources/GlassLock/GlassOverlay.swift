import AppKit
import GlassLockCore

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
    /// Shown large in the middle of every locked screen.
    static let bannerText = "PODEY"
    /// Lifts the centrepiece by this fraction of the screen height, so it sits midway
    /// between the clock and the account details.
    static let centerpieceLift: CGFloat = 0.05

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
        fade(windows, to: 1, duration: 0.35)
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
        panel.stop()
        let closing = windows
        windows.removeAll()
        self.panel = nil
        fade(closing, to: 0, duration: 0.25) {
            closing.forEach { $0.orderOut(nil) }
        }
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
            panel.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            panel.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            panel.topAnchor.constraint(equalTo: content.topAnchor),
            panel.bottomAnchor.constraint(equalTo: content.bottomAnchor),
        ])
        windows.forEach { $0.orderFrontRegardless() }
        host.makeKeyAndOrderFront(nil)
        panel.focusPassword()
    }

    private func fade(_ targets: [ShieldWindow], to alpha: CGFloat, duration: TimeInterval, then completion: (@MainActor @Sendable () -> Void)? = nil) {
        if alpha > 0 {
            targets.forEach { $0.alphaValue = 0 }
        }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = duration
            targets.forEach { $0.animator().alphaValue = alpha }
        }, completionHandler: {
            MainActor.assumeIsolated { completion?() }
        })
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
        addCenterpiece(to: blur, screenSize: screen.frame.size)
        window.contentView = blur
        return window
    }

    /// The user's chosen image centred on the screen, or the PODEY text if none is set.
    static func addCenterpiece(to view: NSView, screenSize: CGSize) {
        if let url = CenterImageStore(directory: AppPaths.supportDirectory).currentURL,
           let image = NSImage(contentsOf: url) {
            addImage(image, to: view, screenSize: screenSize)
        } else {
            addBanner(to: view, screenSize: screenSize)
        }
    }

    private static func addImage(_ image: NSImage, to view: NSView, screenSize: CGSize) {
        let size = CenterImageLayout.fittedSize(image: image.size, screen: screenSize)
        let imageView = NSImageView(image: image)
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.wantsLayer = true
        imageView.layer?.cornerRadius = 20
        imageView.layer?.masksToBounds = true
        imageView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(imageView)
        NSLayoutConstraint.activate([
            imageView.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            imageView.centerYAnchor.constraint(equalTo: view.centerYAnchor, constant: -screenSize.height * centerpieceLift),
            imageView.widthAnchor.constraint(equalToConstant: size.width),
            imageView.heightAnchor.constraint(equalToConstant: size.height),
        ])
    }

    /// Big rounded "PODEY" centred on the screen, sized to the screen width.
    private static func addBanner(to view: NSView, screenSize: CGSize) {
        let size = min(160, max(64, screenSize.width * 0.1))
        var font = NSFont.systemFont(ofSize: size, weight: .black)
        if let rounded = font.fontDescriptor.withDesign(.rounded) {
            font = NSFont(descriptor: rounded, size: size) ?? font
        }
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.3)
        shadow.shadowBlurRadius = 18
        shadow.shadowOffset = NSSize(width: 0, height: -2)
        let banner = NSTextField(labelWithAttributedString: NSAttributedString(string: bannerText, attributes: [
            .font: font,
            .foregroundColor: NSColor.white.withAlphaComponent(0.92),
            .kern: size * 0.08,
            .shadow: shadow,
        ]))
        banner.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(banner)
        NSLayoutConstraint.activate([
            banner.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            banner.centerYAnchor.constraint(equalTo: view.centerYAnchor, constant: -screenSize.height * centerpieceLift),
        ])
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
        panel.focusPassword()
    }
}
