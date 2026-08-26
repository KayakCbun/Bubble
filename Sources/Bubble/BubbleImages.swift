import AppKit
import CryptoKit
import Foundation

enum BubbleImages {
    static func save(_ png: Data) -> String? {
        save(png, mimeType: "image/png")
    }

    static func save(_ data: Data, mimeType: String) -> String? {
        guard !data.isEmpty,
              data.count <= AssistantMessageContent.maxImageBytes,
              mimeType.lowercased().hasPrefix("image/"),
              let image = NSImage(data: data),
              let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let png = bitmap.representation(using: .png, properties: [:]) else { return nil }
        OverlayPaths.bootstrap()
        let digest = SHA256.hash(data: png).map { String(format: "%02x", $0) }.joined()
        let name = digest + ".png"
        let url = OverlayPaths.imagesDirectory.appendingPathComponent(name)
        if FileManager.default.fileExists(atPath: url.path) { return name }
        do {
            try png.write(to: url, options: .atomic)
            return name
        } catch {
            OverlayLog.write("image save failed: \(error.localizedDescription)")
            return nil
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
