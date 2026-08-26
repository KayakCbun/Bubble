import CoreGraphics
import Foundation

struct DraftClip: Equatable, Identifiable {
    enum Kind: Equatable {
        case paste
        case quote
    }

    var id: UUID
    var text: String
    var kind: Kind

    init(id: UUID = UUID(), text: String, kind: Kind = .paste) {
        self.id = id
        self.text = text
        self.kind = kind
    }
}

struct DraftImage: Equatable, Identifiable {
    var id: UUID
    var png: Data

    init(id: UUID = UUID(), png: Data) {
        self.id = id
        self.png = png
    }
}

struct PasteIntake: Equatable {
    var insertText: String = ""
    var clips: [String] = []
    var images: [Data] = []

    var isEmpty: Bool {
        insertText.isEmpty && clips.isEmpty && images.isEmpty
    }
}

enum OverlayComposer {
    static let maxVisibleLines = 6
    static let lineHeight: CGFloat = 20
    static let verticalPadding: CGFloat = 10
    static let attachmentRow: CGFloat = 44
    static let attachmentGap: CGFloat = 6
    static let largePasteCharacters = 1_200
    static let largePasteLines = 8
    static let maxClipCharacters = 32_000
    static let maxImageBytes = 4_000_000
    static let maxImages = 8
    static let displayPreviewCharacters = 240

    static var ceilingHeight: CGFloat {
        verticalPadding * 2
            + max(28, CGFloat(maxVisibleLines) * lineHeight)
            + 8 + 32
            + attachmentGap + attachmentRow
    }

    static let defaultFieldWidth: CGFloat = 420
    static let defaultFontSize: CGFloat = 14

    static let trailingControlSize: CGFloat = 28

    static func fieldWidth(
        inputWidth: CGFloat,
        avatarSize: CGFloat,
        buttonSize: CGFloat = trailingControlSize,
        spacing: CGFloat = 8,
        horizontalPadding: CGFloat = 12
    ) -> CGFloat {
        max(80, inputWidth - horizontalPadding * 2 - avatarSize - buttonSize - spacing * 2)
    }

    static func attachmentChipMaxWidth(
        inputWidth: CGFloat = 520,
        horizontalPadding: CGFloat = 12
    ) -> CGFloat {
        max(120, inputWidth - horizontalPadding * 2)
    }

    static func visibleLineCount(
        _ text: String,
        fieldWidth: CGFloat = defaultFieldWidth,
        fontSize: CGFloat = defaultFontSize
    ) -> Int {
        let paragraphs = text.split(separator: "\n", omittingEmptySubsequences: false)
        var count = 0
        for paragraph in paragraphs {
            count += wrappedLineCount(String(paragraph), fieldWidth: fieldWidth, fontSize: fontSize)
        }
        return min(max(count, 1), maxVisibleLines)
    }

    static func wrappedLineCount(
        _ line: String,
        fieldWidth: CGFloat,
        fontSize: CGFloat
    ) -> Int {
        if line.isEmpty { return 1 }
        let width = estimatedWidth(line, fontSize: fontSize)
        return max(1, Int(ceil(width / max(fieldWidth, fontSize))))
    }

    static func estimatedWidth(_ text: String, fontSize: CGFloat) -> CGFloat {
        var width: CGFloat = 0
        for character in text {
            if character.isNewline { continue }
            if character.isASCII {
                width += fontSize * (character.isWhitespace ? 0.32 : 0.56)
            } else {
                width += fontSize
            }
        }
        return width
    }

    static func isLargePaste(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.count >= largePasteCharacters { return true }
        return trimmed.components(separatedBy: "\n").count >= largePasteLines
    }

    static func composerHeight(
        draft: String,
        minHeight: CGFloat,
        avatarSize: CGFloat,
        workspaceChip: Bool,
        chipHeight: CGFloat,
        attachmentCount: Int,
        fieldWidth: CGFloat = defaultFieldWidth,
        fontSize: CGFloat = defaultFontSize
    ) -> CGFloat {
        let lines = visibleLineCount(draft, fieldWidth: fieldWidth, fontSize: fontSize)
        var extra: CGFloat = 0
        if workspaceChip {
            extra += 8 + chipHeight
        }
        if attachmentCount > 0 {
            extra += attachmentGap + attachmentRow
        }
        if lines <= 1, extra == 0 {
            return minHeight
        }
        let textHeight = CGFloat(lines) * lineHeight
        let row = max(avatarSize, textHeight)
        return verticalPadding * 2 + row + extra
    }

    static func chromeHeightNeedsUpdate(previous: CGFloat, next: CGFloat) -> Bool {
        abs(previous - next) > 0.5
    }

    static func intake(text: String, imagePNG: Data?, fileURLs: [URL] = []) -> PasteIntake {
        var result = PasteIntake()
        if let png = imagePNG, png.count <= maxImageBytes {
            result.images.append(png)
        }
        if result.images.isEmpty {
            for url in fileURLs {
                if result.images.count >= maxImages { break }
                if let png = pngFile(url), png.count <= maxImageBytes {
                    result.images.append(png)
                }
            }
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return result }
        if !result.images.isEmpty, isPathOnly(trimmed, files: fileURLs) {
            return result
        }
        if isLargePaste(text) {
            let clipped = trimmed.count > maxClipCharacters
                ? String(trimmed.prefix(maxClipCharacters)) + "\n…"
                : trimmed
            result.clips.append(clipped)
        } else {
            result.insertText = text
        }
        return result
    }

    static func sendPayload(draft: String, clips: [DraftClip], imageCount: Int) -> (display: String, prompt: String) {
        var display: [String] = []
        var prompt: [String] = []
        let caption = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        if !caption.isEmpty {
            display.append(caption)
            prompt.append(caption)
        }
        for clip in clips {
            let body = clip.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !body.isEmpty else { continue }
            prompt.append(promptFragment(for: clip))
            switch clip.kind {
            case .quote:
                display.append(clipLabel(clip))
            case .paste:
                display.append(clipPreview(body))
            }
        }
        if imageCount == 1 {
            prompt.append("[Image attached]")
        } else if imageCount > 1 {
            prompt.append("[\(imageCount) images attached]")
        }
        return (
            display.joined(separator: "\n\n"),
            prompt.joined(separator: "\n\n")
        )
    }

    static func clipPreview(_ text: String) -> String {
        if text.count <= displayPreviewCharacters {
            return text
        }
        let head = String(text.prefix(displayPreviewCharacters))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return "\(head)\n… (\(text.count) characters)"
    }

    static func clipLabel(_ text: String) -> String {
        clipLabel(DraftClip(text: text, kind: .paste))
    }

    static func clipLabel(_ clip: DraftClip) -> String {
        let body = clip.text.trimmingCharacters(in: .whitespacesAndNewlines)
        switch clip.kind {
        case .quote:
            let compact = body.replacingOccurrences(of: "\n", with: " ")
            if compact.count <= 42 {
                return "Quote · \(compact)"
            }
            return "Quote · \(compact.prefix(41))…"
        case .paste:
            let count = body.count
            let formatter = NumberFormatter()
            formatter.numberStyle = .decimal
            let shown = formatter.string(from: NSNumber(value: count)) ?? "\(count)"
            return "Pasted text · \(shown) characters"
        }
    }

    static func promptFragment(for clip: DraftClip) -> String {
        let body = clip.text.trimmingCharacters(in: .whitespacesAndNewlines)
        switch clip.kind {
        case .paste:
            return body
        case .quote:
            return "Quoted from the conversation:\n\(body)"
        }
    }

    private static func isPathOnly(_ text: String, files: [URL]) -> Bool {
        let lines = text
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard !lines.isEmpty else { return false }
        let names = Set(files.map { $0.path } + files.map { $0.lastPathComponent })
        return lines.allSatisfy { names.contains($0) }
    }

    private static func pngFile(_ url: URL) -> Data? {
        let ext = url.pathExtension.lowercased()
        let images: Set<String> = ["png", "jpg", "jpeg", "gif", "webp", "tif", "tiff", "heic", "bmp"]
        guard images.contains(ext) else { return nil }
        return try? Data(contentsOf: url)
    }
}
