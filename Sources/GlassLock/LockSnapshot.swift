import AppKit

/// Developer aid (`--dev-snapshot <path>`): renders the main-screen lock layout to a PNG
/// without covering the screen. The live blur and the system Touch ID glyph cannot be
/// drawn off-screen, so a dark gradient stands in for the blur and the glyph slot is empty.
@MainActor
enum LockSnapshot {
    static func write(to path: String) {
        let screen = NSScreen.main ?? NSScreen.screens[0]
        let size = screen.frame.size
        let root = NSView(frame: NSRect(origin: .zero, size: size))
        root.wantsLayer = true
        let gradient = CAGradientLayer()
        gradient.frame = root.bounds
        gradient.colors = [NSColor(calibratedRed: 0.25, green: 0.3, blue: 0.4, alpha: 1).cgColor,
                           NSColor(calibratedRed: 0.12, green: 0.14, blue: 0.2, alpha: 1).cgColor]
        root.layer?.addSublayer(gradient)
        GlassOverlay.addCenterpiece(to: root, screenSize: size)

        let panel = UnlockPanel(caption: "Locked from iPhone · 11:40")
        panel.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(panel)
        NSLayoutConstraint.activate([
            panel.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            panel.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            panel.topAnchor.constraint(equalTo: root.topAnchor),
            panel.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])
        let window = NSWindow(contentRect: root.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = root
        root.layoutSubtreeIfNeeded()

        guard let bitmap = root.bitmapImageRepForCachingDisplay(in: root.bounds) else { return }
        root.cacheDisplay(in: root.bounds, to: bitmap)
        try? bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
        panel.stop()
    }
}
