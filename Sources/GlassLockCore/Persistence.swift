import Foundation

public enum AppPaths {
    public static var supportDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("GlassLock", isDirectory: true)
    }

    public static var logFile: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/GlassLock.log")
    }
}

func ensurePrivateDirectory(_ url: URL) throws {
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
}

/// The ntfy topic, kept in a 0600 file (not the Keychain: ad-hoc re-signing on
/// every rebuild would trigger Keychain access prompts).
public struct TopicStore {
    public let fileURL: URL

    public init(directory: URL) {
        fileURL = directory.appendingPathComponent("topic")
    }

    /// Returns the saved topic, creating a new one only if none is saved or it is invalid.
    public func loadOrCreate() throws -> String {
        if let raw = try? String(contentsOf: fileURL, encoding: .utf8) {
            let topic = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if Secret.isValidTopic(topic) {
                return topic
            }
        }
        return try reset()
    }

    @discardableResult
    public func reset() throws -> String {
        let topic = Secret.makeTopic()
        try ensurePrivateDirectory(fileURL.deletingLastPathComponent())
        try Data(topic.utf8).write(to: fileURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
        return topic
    }
}

/// Present while a glass lock is up. Found at launch → the app crashed mid-lock.
public struct CrashFlag {
    public let fileURL: URL

    public init(directory: URL) {
        fileURL = directory.appendingPathComponent("glass-locked")
    }

    public var isSet: Bool {
        FileManager.default.fileExists(atPath: fileURL.path)
    }

    public func set(_ on: Bool) throws {
        if on {
            try ensurePrivateDirectory(fileURL.deletingLastPathComponent())
            try Data().write(to: fileURL)
        } else if isSet {
            try FileManager.default.removeItem(at: fileURL)
        }
    }
}
