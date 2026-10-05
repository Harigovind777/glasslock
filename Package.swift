// swift-tools-version:6.0
import Foundation
import PackageDescription

// Command Line Tools (no Xcode) intermittently drop the Swift Testing macro plugin path
// when recompiling tests ("plugin for module 'TestingMacros' not found"). Pass it explicitly.
let testingPluginPath = "/Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing"
let testSettings: [SwiftSetting] = FileManager.default.fileExists(atPath: testingPluginPath)
    ? [.unsafeFlags(["-plugin-path", testingPluginPath])]
    : []

let package = Package(
    name: "GlassLock",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "GlassLock", targets: ["GlassLock"]),
    ],
    targets: [
        .target(name: "GlassLockCore"),
        .executableTarget(name: "GlassLock", dependencies: ["GlassLockCore"]),
        .testTarget(name: "GlassLockCoreTests", dependencies: ["GlassLockCore"], swiftSettings: testSettings),
    ],
    swiftLanguageModes: [.v5]
)
