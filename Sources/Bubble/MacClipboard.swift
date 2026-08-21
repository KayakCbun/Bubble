import AppKit
import Foundation

struct ClipboardSnapshot: Equatable {
    var text: String = ""
    var imagePNG: Data? = nil
    var fileURLs: [URL] = []

    var isEmpty: Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && imagePNG == nil
            && fileURLs.isEmpty
    }

    var summary: String {
        var parts: [String] = []
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            let count = trimmed.count
            parts.append(count <= 40 ? trimmed : "text \(count) chars")
        }
        if imagePNG != nil {
            parts.append("image")
        }
        if !fileURLs.isEmpty {
            if fileURLs.count == 1 {
                parts.append(fileURLs[0].lastPathComponent)
            } else {
                parts.append("\(fileURLs.count) files")
            }
        }
        return parts.isEmpty ? "empty" : parts.joined(separator: " · ")
    }
}

enum MacClipboard {
    static var hasContent: Bool {
        let board = NSPasteboard.general
        guard let items = board.pasteboardItems, !items.isEmpty else { return false }
        return items.contains { item in
            item.types.contains(.string)
                || item.types.contains(.fileURL)
                || item.types.contains(.png)
                || item.types.contains(.tiff)
                || item.types.contains(.URL)
        } || NSImage(pasteboard: board) != nil
    }

    static func snapshot() -> ClipboardSnapshot {
        let board = NSPasteboard.general
        var snap = ClipboardSnapshot()
        if let string = board.string(forType: .string)?
            .trimmingCharacters(in: CharacterSet(charactersIn: "\u{feff}")) {
            snap.text = string
        }
        snap.fileURLs = fileURLs(from: board)
        if snap.text.isEmpty, let url = snap.fileURLs.first {
            snap.text = url.path
        }
        if let png = board.data(forType: .png), !png.isEmpty {
            snap.imagePNG = png
        } else if snap.fileURLs.isEmpty {
            snap.imagePNG = pngImage(from: board)
        }
        return snap
    }

    static func mentionsClipboard(_ text: String) -> Bool {
        let lowered = text.lowercased()
        let needles = ["@clipboard", "clipboard", "剪贴板", "剪切板", "粘贴板", "剪貼簿"]
        return needles.contains { lowered.contains($0) }
    }

    static func expand(
        _ text: String,
        force: Bool = false
    ) -> (text: String, attachments: [PromptAttachment], images: [PromptImage]) {
        let token = "@clipboard"
        let hadToken = text.localizedCaseInsensitiveContains(token)
        var stripped = text
        while let range = stripped.range(of: token, options: .caseInsensitive) {
            stripped.replaceSubrange(range, with: "")
        }
        stripped = stripped.replacingOccurrences(of: "  ", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        let wants = force || hadToken || mentionsClipboard(text)
        guard wants else {
            return (text, [], [])
        }

        let snap = snapshot()
        var attachments: [PromptAttachment] = []
        var images: [PromptImage] = []
        var blocks: [String] = []

        if snap.isEmpty {
            blocks.append("[Clipboard is empty]")
        } else {
            let trimmed = snap.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                let clipped = trimmed.count > 32_000
                    ? String(trimmed.prefix(32_000)) + "\n…"
                    : trimmed
                blocks.append("[Clipboard]\n\(clipped)")
            }
            if let png = snap.imagePNG, png.count <= 4_000_000 {
                images.append(PromptImage(mimeType: "image/png", data: png))
                blocks.append("[Clipboard image attached]")
            } else if snap.imagePNG != nil {
                blocks.append("[Clipboard image omitted: too large]")
            }
            for url in snap.fileURLs {
                attachments.append(
                    PromptAttachment(
                        uri: url.absoluteString,
                        name: url.lastPathComponent
                    )
                )
                blocks.append("[Clipboard file] \(url.path)")
            }
        }

        let prompt: String
        if stripped.isEmpty {
            prompt = "Here is my clipboard.\n\n" + blocks.joined(separator: "\n\n")
        } else {
            prompt = stripped + "\n\n" + blocks.joined(separator: "\n\n")
        }
        return (prompt, attachments, images)
    }

    private static func fileURLs(from board: NSPasteboard) -> [URL] {
        if let urls = board.readObjects(forClasses: [NSURL.self], options: [
            .urlReadingFileURLsOnly: true,
        ]) as? [URL], !urls.isEmpty {
            return urls
        }
        if let items = board.pasteboardItems {
            return items.compactMap { item in
                guard let raw = item.string(forType: .fileURL) ?? item.string(forType: .URL) else {
                    return nil
                }
                return URL(string: raw) ?? URL(fileURLWithPath: raw)
            }
        }
        return []
    }

    private static func pngImage(from board: NSPasteboard) -> Data? {
        if let data = board.data(forType: .png), !data.isEmpty {
            return data
        }
        guard let image = NSImage(pasteboard: board) else { return nil }
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .png, properties: [:])
    }
}
