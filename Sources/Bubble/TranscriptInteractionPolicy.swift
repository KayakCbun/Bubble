import Foundation

enum StartupTranscriptPolicy {
    static func isSetupCard(_ text: String, isSystem: Bool) -> Bool {
        isSystem && text.hasPrefix("Set up Bubble")
    }

    static func shouldPresentAfterConnection(hasCredentials: Bool) -> Bool {
        !hasCredentials
    }
}

enum ConversationBranchControlsPolicy {
    static func showsInlineRow(isHovered: Bool, variantCount: Int) -> Bool {
        variantCount > 0
    }
}

enum TranscriptFollowPolicy {
    static func followsContentHeightChange(isBusy: Bool) -> Bool {
        isBusy
    }
}
