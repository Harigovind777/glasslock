import AppKit
import GlassLockCore
@preconcurrency import LocalAuthentication
import LocalAuthenticationEmbeddedUI

/// Frosted card: lock icon, caption, embedded Touch ID prompt, password field, status line.
@MainActor
final class UnlockPanel: NSVisualEffectView {
    var onUnlocked: () -> Void = {}
    var onPasswordFailed: () -> Void = {}

    let passwordField = NSSecureTextField()
    private let statusLabel = NSTextField(labelWithString: "Touch ID or enter your password")
    private let touchIDSlot = NSView()
    private var context: LAContext?
    private var verifying = false

    init(caption: String) {
        super.init(frame: .zero)
        material = .hudWindow
        blendingMode = .withinWindow
        state = .active
        wantsLayer = true
        layer?.cornerRadius = 18
        layer?.masksToBounds = true

        let icon = NSImageView(image: NSImage(systemSymbolName: "lock.fill", accessibilityDescription: "Locked")!)
        icon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 28, weight: .semibold)
        icon.contentTintColor = .white

        let captionLabel = NSTextField(labelWithString: caption)
        captionLabel.font = .systemFont(ofSize: 15, weight: .semibold)
        captionLabel.textColor = .white

        statusLabel.font = .systemFont(ofSize: 12)
        statusLabel.textColor = NSColor.white.withAlphaComponent(0.8)

        passwordField.placeholderString = "Mac password"
        passwordField.target = self
        passwordField.action = #selector(submit)
        passwordField.translatesAutoresizingMaskIntoConstraints = false
        passwordField.widthAnchor.constraint(equalToConstant: 240).isActive = true

        touchIDSlot.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            touchIDSlot.widthAnchor.constraint(equalToConstant: 64),
            touchIDSlot.heightAnchor.constraint(equalToConstant: 64),
        ])

        let stack = NSStackView(views: [icon, captionLabel, touchIDSlot, passwordField, statusLabel])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 12
        stack.edgeInsets = NSEdgeInsets(top: 24, left: 32, bottom: 24, right: 32)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("UnlockPanel is created in code only")
    }

    // MARK: Touch ID

    func startTouchID() {
        let context = LAContext()
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error) else {
            touchIDSlot.isHidden = true
            statusLabel.stringValue = "Touch ID unavailable — enter your password"
            Log.write("touch id unavailable: \(error?.localizedDescription ?? "unknown")")
            return
        }
        self.context = context
        let view = LAAuthenticationView(context: context, controlSize: .large)
        view.translatesAutoresizingMaskIntoConstraints = false
        touchIDSlot.subviews.forEach { $0.removeFromSuperview() }
        touchIDSlot.addSubview(view)
        NSLayoutConstraint.activate([
            view.centerXAnchor.constraint(equalTo: touchIDSlot.centerXAnchor),
            view.centerYAnchor.constraint(equalTo: touchIDSlot.centerYAnchor),
        ])
        context.evaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, localizedReason: "unlock GlassLock") { [weak self] success, error in
            DispatchQueue.main.async {
                guard let self, self.context === context else { return }
                if success {
                    Log.write("touch id accepted")
                    self.onUnlocked()
                    return
                }
                let code = (error as? LAError)?.code
                Log.write("touch id ended: \(code.map { String(describing: $0) } ?? "unknown")")
                if code == .biometryLockout || code == .biometryNotAvailable || code == .biometryNotEnrolled {
                    self.touchIDSlot.isHidden = true
                    self.statusLabel.stringValue = "Touch ID locked — enter your password"
                    return
                }
                // Finger not recognised or prompt interrupted: offer Touch ID again.
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
                    guard let self, self.context === context else { return }
                    self.startTouchID()
                }
            }
        }
    }

    func stopTouchID() {
        let context = self.context
        self.context = nil
        context?.invalidate()
    }

    // MARK: Password

    func showRejected(attemptsLeft: Int) {
        statusLabel.stringValue = PasswordInput.rejectionMessage(attemptsLeft: attemptsLeft)
    }

    @objc private func submit() {
        let password = passwordField.stringValue
        guard PasswordInput.isSubmittable(password), !verifying else { return }
        verifying = true
        passwordField.isEnabled = false
        statusLabel.stringValue = "Checking…"
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let accepted = PasswordVerifier.verify(password)
            DispatchQueue.main.async {
                guard let self else { return }
                self.verifying = false
                self.passwordField.isEnabled = true
                self.passwordField.stringValue = ""
                self.window?.makeFirstResponder(self.passwordField)
                if accepted {
                    Log.write("password accepted")
                    self.onUnlocked()
                } else {
                    Log.write("password rejected")
                    self.statusLabel.stringValue = "Wrong password"
                    self.shake()
                    self.onPasswordFailed()
                }
            }
        }
    }

    private func shake() {
        let animation = CAKeyframeAnimation(keyPath: "position.x")
        animation.values = [0, -10, 10, -6, 6, 0]
        animation.isAdditive = true
        animation.duration = 0.35
        layer?.add(animation, forKey: "shake")
    }
}
