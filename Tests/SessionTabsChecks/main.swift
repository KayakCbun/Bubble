import Foundation
import BubbleSessions

private func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else {
        fputs("FAIL: \(message)\n", stderr)
        exit(1)
    }
}

do {
    let first = UUID()
    var state = SessionTabsState(primaryID: first)
    expect(!state.showsTabs, "one session must not show tabs")

    let second = UUID()
    _ = try state.createSideSession(id: second)
    expect(state.showsTabs, "two sessions must show tabs")
    expect(state.selectedID == second, "new side session must be selected")
    expect(state.tabs.map(\.ordinal) == [1, 2], "tabs must keep stable ordinals")

    try state.requestSelection(first)
    expect(state.selectedID == second, "requesting a switch must keep the current transcript for the loading frame")
    expect(state.presentedSelectedID == first, "the requested tab must highlight immediately")
    expect(state.isSwitching, "requesting a switch must show the loading mask immediately")
    expect(state.commitRequestedSelection() == first, "the next frame must commit the requested session")
    expect(state.selectedID == first, "committing must activate the requested session")
    expect(state.isSwitching, "loading must remain while the new transcript renders")
    try state.requestSelection(first)
    expect(state.isSwitching, "re-clicking the rendering tab must not dismiss loading")
    state.finishSelection(first)
    expect(!state.isSwitching, "the new transcript's first frame must dismiss loading")

    let cancellationPrimary = UUID()
    let cancellationSide = UUID()
    var cancellationState = SessionTabsState(primaryID: cancellationPrimary)
    _ = try cancellationState.createSideSession(id: cancellationSide)
    expect(
        SessionSelectionRequestPolicy.shouldForward(
            requestedID: cancellationPrimary,
            activeID: cancellationSide,
            phase: cancellationState.selectionPhase
        ),
        "a different tab must always begin the uniform loading transition"
    )
    try cancellationState.requestSelection(cancellationPrimary)
    expect(
        SessionSelectionRequestPolicy.shouldForward(
            requestedID: cancellationSide,
            activeID: cancellationSide,
            phase: cancellationState.selectionPhase
        ),
        "clicking back to the active transcript must cancel an in-flight switch"
    )
    try cancellationState.requestSelection(cancellationSide)
    expect(!cancellationState.isSwitching, "the last click must cancel the pending transition")
    expect(cancellationState.commitRequestedSelection() == nil, "a cancelled transition must never commit")
    try state.setBusy(true, for: second)
    try state.markUpdated(second)
    expect(state.tabs[1].isBusy, "background busy state must be retained")
    expect(state.tabs[1].hasUnread, "background update must mark the tab unread")

    try state.requestSelection(second)
    _ = state.commitRequestedSelection()
    state.finishSelection(second)
    expect(state.tabs[1].isBusy, "selection must not clear busy state")
    expect(!state.tabs[1].hasUnread, "selection must clear unread state")

    for _ in 0..<3 {
        _ = try state.createSideSession(id: UUID())
    }
    expect(state.tabs.count == 5, "session count must reach five")
    do {
        _ = try state.createSideSession(id: UUID())
        expect(false, "sixth session must fail")
    } catch {
        expect(error as? SessionTabsError == .limitReached(maximum: 5), "sixth session must report the limit")
    }

    let hitRegions = SessionTabLayout.hitRegions(
        count: 2,
        transcriptOriginY: 36,
        trailingX: 36
    )
    expect(hitRegions == [
        CGRect(x: 4, y: 60, width: 32, height: 32),
        CGRect(x: 4, y: 100, width: 32, height: 32),
    ], "physical hit regions must match the rendered tab strip")
    expect(
        SessionTabLayout.index(
            at: CGPoint(x: 29, y: 76),
            count: 2,
            transcriptOriginY: 36,
            trailingX: 36
        ) == 0,
        "a physical click on the first visible tab must resolve to the main session"
    )
    expect(
        SessionTabLayout.index(
            at: CGPoint(x: 29, y: 116),
            count: 2,
            transcriptOriginY: 36,
            trailingX: 36
        ) == 1,
        "a physical click on the second visible tab must resolve to the side session"
    )

    let restoredPrimary = UUID()
    let restoredSide = UUID()
    let savedTabs = SessionTabsSnapshot(
        entries: [
            PersistedSessionTab(runtimeID: restoredPrimary, sessionID: "main-session", role: .main),
            PersistedSessionTab(runtimeID: restoredSide, sessionID: "side-session", role: .side),
        ],
        selectedRuntimeID: restoredSide
    )
    let encoded = try JSONEncoder().encode(savedTabs)
    let decoded = try JSONDecoder().decode(SessionTabsSnapshot.self, from: encoded)
    expect(decoded == savedTabs, "parallel session tabs must survive a persistence round trip")
    let restoredState = try SessionTabsState(snapshot: decoded)
    expect(restoredState.tabs.map(\.id) == [restoredPrimary, restoredSide], "restart must restore every session tab")
    expect(restoredState.selectedID == restoredSide, "restart must restore the selected session tab")
    let temporaryTabsFile = FileManager.default.temporaryDirectory
        .appendingPathComponent("bubble-session-tabs-\(UUID().uuidString).json")
    defer { try? FileManager.default.removeItem(at: temporaryTabsFile) }
    try SessionTabsPersistence.save(savedTabs, to: temporaryTabsFile)
    expect(
        SessionTabsPersistence.load(from: temporaryTabsFile) == savedTabs,
        "restart must restore parallel session tabs from the durable file"
    )

    expect(
        ResumeDestinationPolicy.requiresChoice(sessionID: "another", currentSessionID: "current"),
        "resuming another saved session must ask where to open it"
    )
    expect(
        !ResumeDestinationPolicy.requiresChoice(sessionID: "current", currentSessionID: "current"),
        "resuming the already open session must not ask a meaningless destination question"
    )

    var resumePrompt = ResumeDestinationState()
    resumePrompt.request(sessionID: "saved-session")
    expect(
        resumePrompt.prompt == ResumeDestinationPrompt(sessionID: "saved-session"),
        "resume must expose a transient in-conversation destination prompt"
    )
    expect(
        resumePrompt.choose(.side) == .actionQueued,
        "choosing side resume must queue its action behind immediate UI feedback"
    )
    expect(resumePrompt.prompt == nil, "choosing a destination must dismiss the prompt")
    expect(resumePrompt.isPerformingAction, "resume action must expose loading immediately")
    expect(
        resumePrompt.takePendingAction() == .side(sessionID: "saved-session"),
        "queued side resume must retain the requested session id"
    )
    expect(!resumePrompt.isPerformingAction, "taking the action must clear transient loading")

    resumePrompt.request(sessionID: "replacement")
    expect(
        resumePrompt.choose(.replaceCurrent) == .actionQueued,
        "choosing replace must queue its action behind immediate UI feedback"
    )
    expect(resumePrompt.prompt == nil, "replace must not leave prompt UI behind")
    expect(
        resumePrompt.takePendingAction() == .replaceCurrent(sessionID: "replacement"),
        "queued replacement must retain the requested session id"
    )

    resumePrompt.request(sessionID: "cancelled")
    expect(resumePrompt.choose(.cancel) == .cancelled, "cancel must resolve without a destination")
    expect(resumePrompt.prompt == nil, "cancel must remove the prompt without residue")
    expect(!resumePrompt.isPerformingAction, "cancel must not flash an action loading mask")

    expect(
        SessionTabPreviewPolicy.summary(from: "  研究一下这个仓库\n下一步给出方案  ")
            == "研究一下这个仓库 下一步给出方案",
        "tab preview must summarize the first user input as compact readable text"
    )
    expect(
        SessionTabPreviewPolicy.summary(from: "1234567890ABCDE", maxCharacters: 10)
            == "123456789…",
        "tab preview must stay bounded inside its hover card"
    )
    expect(
        SessionTabPreviewPolicy.summary(from: nil) == "New session",
        "a tab without user input must still explain what it contains"
    )
} catch {
    fputs("FAIL: unexpected error: \(error)\n", stderr)
    exit(1)
}

print("PASS: session tab state checks")
