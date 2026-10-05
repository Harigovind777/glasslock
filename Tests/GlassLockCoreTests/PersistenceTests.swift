import Foundation
import Testing
@testable import GlassLockCore

@Suite struct PersistenceTests {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("glasslock-tests-\(UUID().uuidString)")

    @Test func createsTopicWhenMissingWithPrivatePermissions() throws {
        let store = TopicStore(directory: directory)
        let topic = try store.loadOrCreate()
        #expect(Secret.isValidTopic(topic))
        let fileMode = try FileManager.default.attributesOfItem(atPath: store.fileURL.path)[.posixPermissions] as? Int
        #expect(fileMode == 0o600)
        let dirMode = try FileManager.default.attributesOfItem(atPath: directory.path)[.posixPermissions] as? Int
        #expect(dirMode == 0o700)
    }

    @Test func returnsSameTopicOnReload() throws {
        let first = try TopicStore(directory: directory).loadOrCreate()
        let second = try TopicStore(directory: directory).loadOrCreate()
        #expect(first == second)
    }

    @Test func trailingNewlineKeepsSameTopic() throws {
        let store = TopicStore(directory: directory)
        let topic = try store.loadOrCreate()
        try Data((topic + "\n").utf8).write(to: store.fileURL)
        #expect(try store.loadOrCreate() == topic)
    }

    @Test func invalidContentIsReplaced() throws {
        let store = TopicStore(directory: directory)
        _ = try store.loadOrCreate()
        try Data("garbage".utf8).write(to: store.fileURL)
        let topic = try store.loadOrCreate()
        #expect(Secret.isValidTopic(topic))
        #expect(try String(contentsOf: store.fileURL, encoding: .utf8) == topic)
    }

    @Test func resetChangesTopic() throws {
        let store = TopicStore(directory: directory)
        let old = try store.loadOrCreate()
        let new = try store.reset()
        #expect(old != new)
        #expect(try store.loadOrCreate() == new)
    }

    @Test func crashFlagSetsAndClears() throws {
        let flag = CrashFlag(directory: directory)
        #expect(!flag.isSet)
        try flag.set(true)
        #expect(flag.isSet)
        try flag.set(false)
        #expect(!flag.isSet)
        try flag.set(false)
        #expect(!flag.isSet)
    }
}
