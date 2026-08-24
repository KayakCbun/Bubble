import Foundation

enum PromptTriggerPolicy {
    static func hasActiveTrigger(in draft: String) -> Bool {
        if draft.hasPrefix("/") { return true }
        guard let last = draft.split(whereSeparator: \.isWhitespace).last,
              let first = last.first else { return false }
        return first == "/" || first == "@" || first == "$"
    }
}
