import CoreGraphics
import Foundation

struct WorkspaceStage: Equatable {
    var path: String
    var name: String
    var runId: String?
    var sessionId: String?
    var cardId: UUID
    var followLatest: Bool
    var anchorEntryId: String?
}

enum SideStageEscape: Equatable {
    case returnToWorkspace
    case closeStage
    case ignore
}

enum SideStagePolicy {
    static func width(
        showingMarkdown: Bool,
        showingWorkspace: Bool,
        markdownWidth: CGFloat,
        workspaceWidth: CGFloat
    ) -> CGFloat {
        if showingMarkdown { return markdownWidth }
        if showingWorkspace { return workspaceWidth }
        return 0
    }

    static func isPresented(showingMarkdown: Bool, showingWorkspace: Bool) -> Bool {
        showingMarkdown || showingWorkspace
    }

    static func showsWorkspaceTranscript(showingMarkdown: Bool, showingWorkspace: Bool) -> Bool {
        showingWorkspace && !showingMarkdown
    }

    static func canReturnToWorkspace(showingMarkdown: Bool, workspaceStacked: Bool) -> Bool {
        showingMarkdown && workspaceStacked
    }

    static func followLatest(status: String?) -> Bool {
        status == "running" || status == "waiting"
    }

    static func escapeAction(showingMarkdown: Bool, workspaceStacked: Bool, showingWorkspace: Bool) -> SideStageEscape {
        if showingMarkdown, workspaceStacked {
            return .returnToWorkspace
        }
        if showingMarkdown || showingWorkspace {
            return .closeStage
        }
        return .ignore
    }

    static func shouldToggleClosed(openCardId: UUID?, tappedCardId: UUID) -> Bool {
        openCardId == tappedCardId
    }

    static func keepWorkspaceWhenOpeningMarkdown(fromWorkspacePane: Bool) -> Bool {
        fromWorkspacePane
    }

    static func matchUserTurn(goal: String, turns: [(id: String, text: String)]) -> String? {
        let needle = goal.trimmingCharacters(in: .whitespacesAndNewlines)
        if needle.isEmpty {
            return turns.last?.id
        }
        return matchedUserTurn(needle: needle, turns: turns) ?? turns.last?.id
    }

    private static func matchedUserTurn(
        needle: String,
        turns: [(id: String, text: String)]
    ) -> String? {
        if let exact = turns.last(where: { $0.text == needle }) {
            return exact.id
        }
        if let prefixed = turns.last(where: { $0.text.hasPrefix(needle) || needle.hasPrefix($0.text) }) {
            return prefixed.id
        }
        if let contained = turns.last(where: { $0.text.contains(needle) || needle.contains($0.text) }) {
            return contained.id
        }
        return nil
    }

    static func anchorEntryId(
        stored: String?,
        goal: String,
        cardIndex: Int?,
        turns: [(id: String, text: String)]
    ) -> String? {
        if let stored, turns.contains(where: { $0.id == stored }) {
            return stored
        }
        let needle = goal.trimmingCharacters(in: .whitespacesAndNewlines)
        if !needle.isEmpty,
           let matched = matchedUserTurn(needle: needle, turns: turns) {
            return matched
        }
        if let cardIndex, cardIndex >= 0, cardIndex < turns.count {
            return turns[cardIndex].id
        }
        return matchUserTurn(goal: goal, turns: turns)
    }

    static func scrollTarget(followLatest: Bool, anchorEntryId: String?) -> String {
        if followLatest {
            return "workspace-end"
        }
        if let anchorEntryId, !anchorEntryId.isEmpty {
            return "entry-\(anchorEntryId)"
        }
        return "workspace-end"
    }

    /// `session/load` and `session/resume` replay history and set a process-wide
    /// replay flag. Doing that to a live child prompt drops updates and can
    /// clobber main-session steering.
    static func shouldAttachSession(
        sessionId: String,
        liveSessionIds: Set<String>,
        childBusy: Bool
    ) -> Bool {
        if sessionId.isEmpty { return false }
        if childBusy { return false }
        if liveSessionIds.contains(sessionId) { return false }
        return true
    }

    static func shouldReloadOnShow(hasCachedRows: Bool) -> Bool {
        !hasCachedRows
    }
}
