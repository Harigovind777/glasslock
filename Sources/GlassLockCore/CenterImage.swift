import CoreGraphics
import Foundation

/// The optional picture shown in the middle of the lock screen (instead of the PODEY text).
public struct CenterImageStore {
    public enum StoreError: Error, Equatable {
        case unsupportedType(String)
    }

    public static let supportedExtensions = ["png", "jpg", "jpeg", "heic", "tiff", "gif"]
    private static let baseName = "center-image"

    private let directory: URL

    public init(directory: URL) {
        self.directory = directory
    }

    /// The saved image, if one has been chosen.
    public var currentURL: URL? {
        Self.supportedExtensions
            .map { directory.appendingPathComponent("\(Self.baseName).\($0)") }
            .first { FileManager.default.fileExists(atPath: $0.path) }
    }

    /// Copies the image in, replacing any previous one. The extension is kept (lowercased).
    @discardableResult
    public func save(from source: URL) throws -> URL {
        let ext = source.pathExtension.lowercased()
        guard Self.supportedExtensions.contains(ext) else {
            throw StoreError.unsupportedType(ext)
        }
        try clear()
        try ensurePrivateDirectory(directory)
        let destination = directory.appendingPathComponent("\(Self.baseName).\(ext)")
        try FileManager.default.copyItem(at: source, to: destination)
        return destination
    }

    public func clear() throws {
        while let url = currentURL {
            try FileManager.default.removeItem(at: url)
        }
    }
}

public enum CenterImageLayout {
    /// Scales the image to fit within half the screen width and 35% of its height, keeping its shape.
    public static func fittedSize(image: CGSize, screen: CGSize) -> CGSize {
        guard image.width > 0, image.height > 0 else { return .zero }
        let scale = min(screen.width * 0.5 / image.width, screen.height * 0.35 / image.height)
        return CGSize(width: image.width * scale, height: image.height * scale)
    }
}
