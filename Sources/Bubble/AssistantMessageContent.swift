import Foundation

struct AssistantMessageImage: Equatable, Sendable {
    var mimeType: String
    var data: Data

    static func decode(mimeType: String, encoded: String) -> AssistantMessageImage? {
        guard mimeType.lowercased().hasPrefix("image/"),
              let data = Data(base64Encoded: encoded),
              !data.isEmpty,
              data.count <= AssistantMessageContent.maxImageBytes else { return nil }
        return AssistantMessageImage(mimeType: mimeType, data: data)
    }
}

enum AssistantMessageContent: Equatable, Sendable {
    static let maxImageBytes = 20_000_000

    case text(String)
    case image(AssistantMessageImage)

    var text: String? {
        guard case .text(let value) = self else { return nil }
        return value
    }

    var image: AssistantMessageImage? {
        guard case .image(let value) = self else { return nil }
        return value
    }

    static func parse(_ raw: Any?) -> AssistantMessageContent? {
        if let text = raw as? String {
            return text.isEmpty ? nil : .text(text)
        }
        guard let object = raw as? [String: Any],
              let type = object["type"] as? String else { return nil }
        if type == "text", let text = object["text"] as? String, !text.isEmpty {
            return .text(text)
        }
        guard type == "image",
              let mimeType = object["mimeType"] as? String,
              let encoded = object["data"] as? String,
              let image = AssistantMessageImage.decode(mimeType: mimeType, encoded: encoded) else { return nil }
        return .image(image)
    }

    static func images(in raw: Any?) -> [AssistantMessageImage] {
        if let parsed = parse(raw), let image = parsed.image { return [image] }
        if let values = raw as? [Any] {
            return values.flatMap(images(in:))
        }
        guard let object = raw as? [String: Any] else { return [] }
        return images(in: object["content"])
    }

    static func texts(in raw: Any?) -> [String] {
        if let parsed = parse(raw), let text = parsed.text { return [text] }
        if let values = raw as? [Any] {
            return values.flatMap(texts(in:))
        }
        guard let object = raw as? [String: Any] else { return [] }
        return texts(in: object["content"])
    }
}

struct AssistantImagePlacement: Codable, Equatable, Sendable {
    var name: String
    var textOffset: Int
}

enum AssistantPresentationBlock: Equatable, Sendable {
    case text(String)
    case image(String)
}

enum AssistantMessagePresentation {
    static func hasContent(text: String, imageNames: [String]?) -> Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !(imageNames ?? []).isEmpty
    }

    static func blocks(
        text: String,
        imageNames: [String]?,
        placements: [AssistantImagePlacement]?
    ) -> [AssistantPresentationBlock] {
        let names = imageNames ?? []
        let placedNames = Set((placements ?? []).map(\.name))
        var blocks: [AssistantPresentationBlock] = []
        var cursor = text.startIndex
        for placement in (placements ?? []).enumerated().sorted(by: {
            if $0.element.textOffset == $1.element.textOffset { return $0.offset < $1.offset }
            return $0.element.textOffset < $1.element.textOffset
        }).map(\.element) {
            let offset = min(max(placement.textOffset, 0), text.count)
            let boundary = text.index(text.startIndex, offsetBy: offset)
            if cursor < boundary {
                blocks.append(.text(String(text[cursor..<boundary])))
            }
            blocks.append(.image(placement.name))
            cursor = max(cursor, boundary)
        }
        if cursor < text.endIndex {
            blocks.append(.text(String(text[cursor...])))
        }
        let unplaced = names
            .filter { !placedNames.contains($0) }
            .map(AssistantPresentationBlock.image)
        return unplaced + blocks
    }
}
