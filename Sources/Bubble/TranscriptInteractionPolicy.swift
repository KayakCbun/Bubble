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
    static func showsUserVariantSwitcher(variantCount: Int) -> Bool {
        variantCount > 1
    }

    static func showsAssistantBranchAction(hasSourceEntry: Bool, isStreaming: Bool) -> Bool {
        hasSourceEntry && !isStreaming
    }
}

enum TranscriptFollowPolicy {
    static func followsContentHeightChange(isBusy: Bool) -> Bool {
        isBusy
    }
}
