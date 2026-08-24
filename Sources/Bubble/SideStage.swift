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

enum WorkspacePaneSeed: Equatable {
    case current
    case run
    case cached
    case card
    case loading
}

struct WorkspacePaneSeedContext {
    var currentSessionId: String?
    var nextSessionId: String?
    var currentCardId: UUID?
    var nextCardId: UUID
    var hasCurrentRows: Bool
    var hasRunRows: Bool
    var cacheIsFresh: Bool
    var selectedAnchorIsCached: Bool
    var isLive: Bool
}

enum WorkspacePaneLoadState: Equatable {
    case idle
    case loading
    case ready
    case fallback
    case failed
}

enum WorkspacePanePresentationPhase: Equatable {
    case ready
    case placeholder
    case waitingForContent
}

enum SideStageContent: Equatable {
    case hidden
    case placeholder
    case transcript
}

enum SideStagePresentationPolicy {
    static func content(
        workspacePresented: Bool,
        phase: WorkspacePanePresentationPhase
    ) -> SideStageContent {
        guard workspacePresented else { return .hidden }
        return phase == .ready ? .transcript : .placeholder
    }

    /// Keep the Bubble placeholder covering the extra card until transcript
    /// content has been mounted, so the swap cannot flash an empty frame.
    static func placeholderOpacity(coverVisible: Bool) -> Double {
        coverVisible ? 1 : 0
    }

    static func transcriptOpacity(coverVisible: Bool) -> Double {
        coverVisible ? 0 : 1
    }

    static func mountsTranscript(phase: WorkspacePanePresentationPhase) -> Bool {
        phase == .ready
    }
}

enum SideStageChromePolicy {
    static let revealDuration: TimeInterval = 0.16
    static let hideDuration: TimeInterval = 0.14

    /// The extra card fades on the next frame. Waiting for the panel spring to
    /// settle leaves an empty gap that reads as lag.
    static func waitsForPanelSettleToRevealChrome() -> Bool {
        false
    }

    /// A collapsed overlay inserts the extra card at opacity 0 so the fade can
    /// start immediately, with the Bubble placeholder if session content is not ready.
    static func opensHidden(wasPresented: Bool) -> Bool {
        !wasPresented
    }

    /// Closing keeps the extra width until the card has faded out, then slides
    /// the conversation back.
    static func shouldFadeOutBeforeCollapse(chromeVisible: Bool, presented: Bool) -> Bool {
        chromeVisible && presented
    }

    static func opacity(visible: Bool) -> Double {
        visible ? 1 : 0
    }

    /// Reserved space beside the conversation is not a card until chrome is visible.
    static func hitPreviewWidth(chromeVisible: Bool, previewWidth: CGFloat) -> CGFloat {
        chromeVisible ? previewWidth : 0
    }
}

enum WorkspaceRunLifecyclePolicy {
    static func shouldPrepareSession(childBusy: Bool) -> Bool {
        !childBusy
    }

    static func acceptsStreamUpdate(
        routedSessionId: String,
        activeChildSessionId: String?,
        childBusy: Bool
    ) -> Bool {
        guard childBusy else { return false }
        if routedSessionId.isEmpty { return true }
        return routedSessionId == activeChildSessionId
    }

    static func acceptsCompletion(
        expectedGeneration: Int,
        currentGeneration: Int,
        expectedRunId: String,
        activeRunId: String?
    ) -> Bool {
        expectedGeneration == currentGeneration && expectedRunId == activeRunId
    }
}

enum WorkspaceTurnRowKind: Equatable {
    case user
    case assistant
    case thought
    case tool
    case other
}

struct WorkspaceTurnRow: Equatable {
    var id: String
    var sourceEntryId: String?
    var kind: WorkspaceTurnRowKind
}

enum SideStagePolicy {
    static let workspaceLoadFallbackDelay: TimeInterval = 2.5

    static func shouldFallbackWorkspaceLoad(elapsed: TimeInterval) -> Bool {
        elapsed >= workspaceLoadFallbackDelay
    }

    static func shouldReloadWorkspacePaneOnResume(_ state: WorkspacePaneLoadState) -> Bool {
        state != .ready && state != .loading
    }

    static func paneSeed(_ context: WorkspacePaneSeedContext) -> WorkspacePaneSeed {
        guard let nextSessionId = context.nextSessionId, !nextSessionId.isEmpty else {
            return .card
        }
        if context.hasRunRows {
            return .run
        }
        let sameSession = context.currentSessionId == nextSessionId
        if context.isLive {
            if sameSession,
               context.currentCardId == context.nextCardId,
               context.hasCurrentRows {
                return .current
            }
            return .card
        }
        if context.cacheIsFresh, context.selectedAnchorIsCached {
            if sameSession, context.hasCurrentRows {
                return .current
            }
            return .cached
        }
        return .loading
    }

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

    static func scrollTarget(
        followLatest: Bool,
        anchorEntryId: String?,
        rows: [WorkspaceTurnRow] = []
    ) -> String {
        if followLatest {
            return "workspace-end"
        }
        guard let anchorEntryId, !anchorEntryId.isEmpty else { return "workspace-end" }
        guard let userIndex = rows.firstIndex(where: {
            $0.kind == .user && $0.sourceEntryId == anchorEntryId
        }) else { return "entry-\(anchorEntryId)" }
        let nextUserIndex = rows[(userIndex + 1)...].firstIndex(where: { $0.kind == .user })
            ?? rows.endIndex
        let turn = rows[(userIndex + 1)..<nextUserIndex]
        if let assistant = turn.last(where: { $0.kind == .assistant }) {
            return assistant.id
        }
        if let output = turn.last(where: { $0.kind != .user && $0.kind != .other }) {
            return output.id
        }
        return rows[userIndex].id
    }

    static func runRange(
        anchorEntryId: String?,
        rows: [WorkspaceTurnRow]
    ) -> Range<Int>? {
        guard let anchorEntryId, !anchorEntryId.isEmpty,
              let userIndex = rows.firstIndex(where: {
                  $0.kind == .user && $0.sourceEntryId == anchorEntryId
              }) else { return nil }
        let nextUserIndex = rows[(userIndex + 1)...].firstIndex(where: { $0.kind == .user })
            ?? rows.endIndex
        return userIndex..<nextUserIndex
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

    static func acceptsWorkspaceUpdate(stageRunId: String?, incomingRunId: String?) -> Bool {
        guard let incomingRunId, !incomingRunId.isEmpty else { return true }
        return stageRunId == incomingRunId
    }
}
