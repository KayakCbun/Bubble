import Foundation

struct AssistantMessageImage: Equatable, Sendable {
    var mimeType: String
    var data: Data
}

struct AssistantMessageContent: Equatable, Sendable {
    static let maxImageBytes = 20_000_000

    var text: String?
    var image: AssistantMessageImage?

    static func parse(_ raw: Any?) -> AssistantMessageContent? {
        if let text = raw as? String {
            return text.isEmpty ? nil : AssistantMessageContent(text: text, image: nil)
        }
        guard let object = raw as? [String: Any],
              let type = object["type"] as? String else { return nil }
        if type == "text", let text = object["text"] as? String, !text.isEmpty {
            return AssistantMessageContent(text: text, image: nil)
        }
        guard type == "image",
              let mimeType = object["mimeType"] as? String,
              mimeType.lowercased().hasPrefix("image/"),
              let encoded = object["data"] as? String,
              let data = Data(base64Encoded: encoded),
              !data.isEmpty,
              data.count <= maxImageBytes else { return nil }
        return AssistantMessageContent(
            text: nil,
            image: AssistantMessageImage(mimeType: mimeType, data: data)
        )
    }
}

enum AssistantMessagePresentation {
    static func hasContent(text: String, imageNames: [String]?) -> Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !(imageNames ?? []).isEmpty
    }
}
