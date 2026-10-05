// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "GlassLock",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "GlassLockCore"),
        .testTarget(name: "GlassLockCoreTests", dependencies: ["GlassLockCore"]),
    ],
    swiftLanguageModes: [.v5]
)
