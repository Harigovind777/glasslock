import AppKit
import GlassLockCore
@preconcurrency import LocalAuthentication
import LocalAuthenticationEmbeddedUI

/// Full-screen lock content in the style of the macOS lock screen: date and a
/// large clock at the top; account picture, name, caption, password field and
/// Touch ID at the bottom.
@MainActor
final class UnlockPanel: NSView {
    var onUnlocked: () -> Void = {}
    var onPasswordFailed: () -> Void = {}

    let passwordField = NSSecureTextField()
    private let passwordPill = NSView()
    private let dateLabel = UnlockPanel.label("", size: 17, weight: .medium, alpha: 0.85)
    private let timeLabel = UnlockPanel.label("", size: 64, weight: .semibold, alpha: 0.9)
    private let statusLabel = UnlockPanel.label("", size: 12, weight: .medium, alpha: 0.75)
    private let touchIDSlot = NSView()
    private let touchIDBalance = NSView()
    private var defaultStatus = "Touch ID or Enter Password"
    private var context: LAContext?
    private var clockTimer: Timer?
    private var verifying = false
    /// Height of the password field and the Touch ID glyph beside it.
    private static let fieldHeight: CGFloat = 32

    init(caption: String) {
        super.init(frame: .zero)

        let clock = Self.column([dateLabel, timeLabel], spacing: 0)
        [dateLabel, timeLabel].forEach(Self.addSoftShadow)

        let avatar = Self.makeAvatar(diameter: 72)
        let nameLabel = Self.label(UserAccount.displayName, size: 15, weight: .semibold, alpha: 1)
        let captionLabel = Self.label(caption, size: 12, weight: .regular, alpha: 0.7)
        [nameLabel, captionLabel, statusLabel].forEach(Self.addSoftShadow)

        configurePasswordPill()
        // The Touch ID glyph sits right of the field; an equal empty view on the left keeps the field centred.
        for slot in [touchIDSlot, touchIDBalance] {
            slot.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                slot.widthAnchor.constraint(equalToConstant: Self.fieldHeight),
                slot.heightAnchor.constraint(equalToConstant: Self.fieldHeight),
            ])
        }
        let entryRow = NSStackView(views: [touchIDBalance, passwordPill, touchIDSlot])
        entryRow.orientation = .horizontal
        entryRow.alignment = .centerY
        entryRow.spacing = 10
        statusLabel.stringValue = defaultStatus

        let account = Self.column([avatar, nameLabel, captionLabel, entryRow, statusLabel], spacing: 6)
        account.setCustomSpacing(14, after: avatar)
        account.setCustomSpacing(20, after: captionLabel)
        account.setCustomSpacing(12, after: entryRow)

        addSubview(clock)
        addSubview(account)
        NSLayoutConstraint.activate([
            clock.centerXAnchor.constraint(equalTo: centerXAnchor),
            clock.topAnchor.constraint(equalTo: topAnchor, constant: 72),
            account.centerXAnchor.constraint(equalTo: centerXAnchor),
            account.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -88),
        ])

        updateClock()
        clockTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateClock() }
        }
    }

    required init?(coder: NSCoder) {
        fatalError("UnlockPanel is created in code only")
    }

    /// Puts the cursor in the password field (white caret on the dark glass).
    func focusPassword() {
        window?.makeFirstResponder(passwordField)
        (passwordField.currentEditor() as? NSTextView)?.insertionPointColor = .white
    }

    /// Stops Touch ID and the clock. Call when the lock screen goes away.
    func stop() {
        clockTimer?.invalidate()
        clockTimer = nil
        let context = self.context
        self.context = nil
        context?.invalidate()
    }

    // MARK: Touch ID

    func startTouchID() {
        let context = LAContext()
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error) else {
            hideTouchID(status: "Enter Password")
            Log.write("touch id unavailable: \(error?.localizedDescription ?? "unknown")")
            return
        }
        self.context = context
        // .small draws a 32 pt glyph — the same height as the password field.
        let view = LAAuthenticationView(context: context, controlSize: .small)
        view.translatesAutoresizingMaskIntoConstraints = false
        touchIDSlot.subviews.forEach { $0.removeFromSuperview() }
        touchIDSlot.addSubview(view)
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: touchIDSlot.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: touchIDSlot.trailingAnchor),
            view.topAnchor.constraint(equalTo: touchIDSlot.topAnchor),
            view.bottomAnchor.constraint(equalTo: touchIDSlot.bottomAnchor),
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
                    self.hideTouchID(status: "Touch ID is locked — Enter Password")
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

    private func hideTouchID(status: String) {
        touchIDSlot.isHidden = true
        touchIDBalance.isHidden = true
        defaultStatus = status
        statusLabel.stringValue = status
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
                self.focusPassword()
                if accepted {
                    Log.write("password accepted")
                    self.onUnlocked()
                } else {
                    Log.write("password rejected")
                    self.statusLabel.stringValue = "Wrong password"
                    self.shake(self.passwordPill)
                    self.onPasswordFailed()
                }
            }
        }
    }

    // MARK: Building blocks

    private func configurePasswordPill() {
        passwordPill.wantsLayer = true
        passwordPill.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.18).cgColor
        passwordPill.layer?.cornerRadius = Self.fieldHeight / 2
        passwordPill.layer?.borderWidth = 0.5
        passwordPill.layer?.borderColor = NSColor.white.withAlphaComponent(0.25).cgColor
        passwordPill.translatesAutoresizingMaskIntoConstraints = false

        passwordField.isBordered = false
        passwordField.drawsBackground = false
        passwordField.focusRingType = .none
        passwordField.alignment = .center
        passwordField.font = .systemFont(ofSize: 13)
        passwordField.textColor = .white
        let centered = NSMutableParagraphStyle()
        centered.alignment = .center
        passwordField.placeholderAttributedString = NSAttributedString(
            string: "Enter Password",
            attributes: [
                .foregroundColor: NSColor.white.withAlphaComponent(0.55),
                .font: NSFont.systemFont(ofSize: 13),
                .paragraphStyle: centered,
            ])
        passwordField.target = self
        passwordField.action = #selector(submit)
        passwordField.translatesAutoresizingMaskIntoConstraints = false
        passwordPill.addSubview(passwordField)
        NSLayoutConstraint.activate([
            passwordPill.widthAnchor.constraint(equalToConstant: 220),
            passwordPill.heightAnchor.constraint(equalToConstant: Self.fieldHeight),
            passwordField.leadingAnchor.constraint(equalTo: passwordPill.leadingAnchor, constant: 14),
            passwordField.trailingAnchor.constraint(equalTo: passwordPill.trailingAnchor, constant: -14),
            passwordField.centerYAnchor.constraint(equalTo: passwordPill.centerYAnchor),
        ])
    }

    private func updateClock() {
        let now = Date()
        timeLabel.stringValue = Self.timeFormatter.string(from: now)
        dateLabel.stringValue = Self.dateFormatter.string(from: now)
    }

    /// "11:42" — no AM/PM, like the macOS lock screen.
    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        let uses12Hour = DateFormatter.dateFormat(fromTemplate: "j", options: 0, locale: .current)?.contains("a") ?? false
        formatter.dateFormat = uses12Hour ? "h:mm" : "HH:mm"
        return formatter
    }()

    /// "Monday, 5 October" in the user's locale.
    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate("EEEEdMMMM")
        return formatter
    }()

    private static func makeAvatar(diameter: CGFloat) -> NSView {
        let avatar: NSView
        if let picture = UserAccount.picture() {
            let imageView = NSImageView(image: picture)
            imageView.imageScaling = .scaleProportionallyUpOrDown
            avatar = imageView
        } else {
            avatar = NSView()
            avatar.wantsLayer = true
            avatar.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.22).cgColor
            let initials = label(Initials.from(UserAccount.displayName), size: diameter * 0.36, weight: .semibold, alpha: 1)
            initials.translatesAutoresizingMaskIntoConstraints = false
            avatar.addSubview(initials)
            NSLayoutConstraint.activate([
                initials.centerXAnchor.constraint(equalTo: avatar.centerXAnchor),
                initials.centerYAnchor.constraint(equalTo: avatar.centerYAnchor),
            ])
        }
        avatar.wantsLayer = true
        avatar.layer?.cornerRadius = diameter / 2
        avatar.layer?.masksToBounds = true
        avatar.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            avatar.widthAnchor.constraint(equalToConstant: diameter),
            avatar.heightAnchor.constraint(equalToConstant: diameter),
        ])
        return avatar
    }

    private static func label(_ text: String, size: CGFloat, weight: NSFont.Weight, alpha: CGFloat) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: size, weight: weight)
        label.textColor = NSColor.white.withAlphaComponent(alpha)
        label.alignment = .center
        return label
    }

    private static func column(_ views: [NSView], spacing: CGFloat) -> NSStackView {
        let stack = NSStackView(views: views)
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = spacing
        stack.translatesAutoresizingMaskIntoConstraints = false
        return stack
    }

    /// Keeps white text legible over bright parts of the blurred screen.
    private static func addSoftShadow(_ view: NSView) {
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.25)
        shadow.shadowBlurRadius = 6
        shadow.shadowOffset = NSSize(width: 0, height: -1)
        view.shadow = shadow
    }

    private func shake(_ view: NSView) {
        let animation = CAKeyframeAnimation(keyPath: "position.x")
        animation.values = [0, -10, 10, -6, 6, 0]
        animation.isAdditive = true
        animation.duration = 0.35
        view.layer?.add(animation, forKey: "shake")
    }
}
