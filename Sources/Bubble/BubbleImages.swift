import AppKit
import CryptoKit
import Foundation

enum BubbleImages {
    static func save(_ png: Data) -> String? {
        guard !png.isEmpty,
              png.count <= AssistantMessageContent.maxImageBytes else { return nil }
        return write(png, name: UUID().uuidString + ".png")
    }

    static func save(_ data: Data, mimeType: String) -> String? {
        guard !data.isEmpty,
              data.count <= AssistantMessageContent.maxImageBytes,
              mimeType.lowercased().hasPrefix("image/") else { return nil }
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        return write(data, name: digest + fileExtension(for: mimeType))
    }

    private static func write(_ data: Data, name: String) -> String? {
        OverlayPaths.bootstrap()
        let url = OverlayPaths.imagesDirectory.appendingPathComponent(name)
        if FileManager.default.fileExists(atPath: url.path) { return name }
        do {
            try data.write(to: url, options: .atomic)
            return name
        } catch {
            OverlayLog.write("image save failed: \(error.localizedDescription)")
            return nil
        }
    }

    private static func fileExtension(for mimeType: String) -> String {
        switch mimeType.lowercased() {
        case "image/jpeg", "image/jpg": ".jpg"
        case "image/gif": ".gif"
        case "image/webp": ".webp"
        case "image/tiff": ".tiff"
        case "image/heic", "image/heif": ".heic"
        default: ".png"
        }
    }

    static func load(_ name: String) -> NSImage? {
        NSImage(contentsOf: fileURL(name))
    }

    static func fileURL(_ name: String) -> URL {
        let base = (name as NSString).lastPathComponent
        return OverlayPaths.imagesDirectory.appendingPathComponent(base)
    }
}
