import AppKit
import Foundation

enum BubbleImages {
    static func save(_ png: Data) -> String? {
        guard !png.isEmpty else { return nil }
        OverlayPaths.bootstrap()
        let name = UUID().uuidString.lowercased() + ".png"
        let url = OverlayPaths.imagesDirectory.appendingPathComponent(name)
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
