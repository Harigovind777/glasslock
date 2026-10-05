import AppKit
import GlassLockCore

/// Builds "Lock Mac.shortcut" for the topic, signs it with /usr/bin/shortcuts and opens it to import.
enum ShortcutInstaller {
    enum InstallError: Error {
        case signingFailed(String)
    }

    @discardableResult
    static func install(topic: String) throws -> URL {
        let directory = AppPaths.supportDirectory
        let unsigned = directory.appendingPathComponent("unsigned.shortcut")
        let signed = directory.appendingPathComponent("Lock Mac.shortcut")
        try ShortcutBuilder.data(topic: topic).write(to: unsigned, options: .atomic)
        try? FileManager.default.removeItem(at: signed)
        defer { try? FileManager.default.removeItem(at: unsigned) }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/shortcuts")
        process.arguments = ["sign", "--mode", "anyone", "--input", unsigned.path, "--output", signed.path]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0, FileManager.default.fileExists(atPath: signed.path) else {
            let text = String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            throw InstallError.signingFailed(text)
        }
        NSWorkspace.shared.open(signed)
        return signed
    }
}
