import CoreGraphics
import Foundation
import Testing
@testable import GlassLockCore

@Suite struct CenterImageStoreTests {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("glasslock-image-tests-\(UUID().uuidString)")

    func makeSource(_ name: String) throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("src-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent(name)
        try Data("image-bytes-\(name)".utf8).write(to: url)
        return url
    }

    @Test func noImageByDefault() {
        #expect(CenterImageStore(directory: directory).currentURL == nil)
    }

    @Test func saveCopiesImageAndKeepsExtension() throws {
        let store = CenterImageStore(directory: directory)
        let saved = try store.save(from: try makeSource("Podey Malayalam.PNG"))
        #expect(saved.lastPathComponent == "center-image.png")
        #expect(store.currentURL == saved)
        #expect(try Data(contentsOf: saved) == Data("image-bytes-Podey Malayalam.PNG".utf8))
    }

    @Test func savingAgainReplacesPreviousImage() throws {
        let store = CenterImageStore(directory: directory)
        _ = try store.save(from: try makeSource("a.png"))
        let second = try store.save(from: try makeSource("b.jpg"))
        #expect(store.currentURL == second)
        let files = try FileManager.default.contentsOfDirectory(atPath: directory.path).filter { $0.hasPrefix("center-image") }
        #expect(files == ["center-image.jpg"])
    }

    @Test func unsupportedTypeIsRejected() throws {
        let store = CenterImageStore(directory: directory)
        #expect(throws: CenterImageStore.StoreError.unsupportedType("pdf")) {
            try store.save(from: try makeSource("doc.pdf"))
        }
        #expect(store.currentURL == nil)
    }

    @Test func clearRemovesImage() throws {
        let store = CenterImageStore(directory: directory)
        _ = try store.save(from: try makeSource("a.heic"))
        try store.clear()
        #expect(store.currentURL == nil)
        try store.clear()
    }
}

@Suite struct CenterImageLayoutTests {
    let screen = CGSize(width: 1470, height: 956)

    func close(_ a: CGSize, _ b: CGSize) -> Bool {
        abs(a.width - b.width) < 0.01 && abs(a.height - b.height) < 0.01
    }

    @Test func wideImageIsLimitedByHalfTheScreenWidth() {
        let size = CenterImageLayout.fittedSize(image: CGSize(width: 2000, height: 500), screen: screen)
        #expect(close(size, CGSize(width: 735, height: 183.75)))
    }

    @Test func tallImageIsLimitedBy30PercentOfScreenHeight() {
        let size = CenterImageLayout.fittedSize(image: CGSize(width: 400, height: 800), screen: screen)
        #expect(close(size, CGSize(width: 143.4, height: 286.8)))
    }

    @Test func smallImageIsScaledUpToFit() {
        let size = CenterImageLayout.fittedSize(image: CGSize(width: 100, height: 50), screen: screen)
        #expect(close(size, CGSize(width: 573.6, height: 286.8)))
    }

    @Test func emptyImageGivesZero() {
        #expect(CenterImageLayout.fittedSize(image: .zero, screen: screen) == .zero)
    }
}
