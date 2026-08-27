import AppKit
import BubbleMounts
import BubbleSessions
import Foundation
import Observation

struct ChatItem: Identifiable, Codable, Equatable, @unchecked Sendable {
    enum Kind: String, Codable {
        case user
        case assistant
        case thought
        case tool
        case system
        case workspaceRun
    }

    var id: UUID
    var kind: Kind
    var text: String
    var toolId: String?
    var toolStatus: String?
    var toolKind: String?
    var toolInput: String?
    var toolOutput: String?
    var workspacePath: String?
    var workspaceRunId: String?
    var workspaceName: String?
    var workspaceStatus: String?
    var workspaceGoal: String?
    var workspaceSummary: String?
    var workspaceQuestion: String?
    var workspaceChangedPaths: [String]?
    var workspaceChildren: [ChatItem]?
    var workspaceStartedAt: TimeInterval?
    var workspaceAnchorEntryId: String?
    var workspaceSessionId: String?
    var imageNames: [String]?
    var assistantImagePlacements: [AssistantImagePlacement]?
    var deliveryState: MessageDeliveryState?
    var sourceEntryId: String?
    var sourceBranchable: Bool?

    init(
        id: UUID = UUID(),
        kind: Kind,
        text: String,
        toolId: String? = nil,
        toolStatus: String? = nil,
        toolKind: String? = nil,
        toolInput: String? = nil,
        toolOutput: String? = nil,
        workspacePath: String? = nil,
        workspaceRunId: String? = nil,
        workspaceName: String? = nil,
        workspaceStatus: String? = nil,
        workspaceGoal: String? = nil,
        workspaceSummary: String? = nil,
        workspaceQuestion: String? = nil,
        workspaceChangedPaths: [String]? = nil,
        workspaceChildren: [ChatItem]? = nil,
        workspaceStartedAt: TimeInterval? = nil,
        workspaceAnchorEntryId: String? = nil,
        workspaceSessionId: String? = nil,
        imageNames: [String]? = nil,
        assistantImagePlacements: [AssistantImagePlacement]? = nil,
        deliveryState: MessageDeliveryState? = nil,
        sourceEntryId: String? = nil,
        sourceBranchable: Bool? = nil
    ) {
        self.id = id
        self.kind = kind
        self.text = text
        self.toolId = toolId
        self.toolStatus = toolStatus
        self.toolKind = toolKind
        self.toolInput = toolInput
        self.toolOutput = toolOutput
        self.workspacePath = workspacePath
        self.workspaceRunId = workspaceRunId
        self.workspaceName = workspaceName
        self.workspaceSummary = workspaceSummary
        self.workspaceStatus = workspaceStatus
        self.workspaceGoal = workspaceGoal
        self.workspaceQuestion = workspaceQuestion
        self.workspaceChangedPaths = workspaceChangedPaths
        self.workspaceChildren = workspaceChildren
        self.workspaceStartedAt = workspaceStartedAt
        self.workspaceAnchorEntryId = workspaceAnchorEntryId
        self.workspaceSessionId = workspaceSessionId
        self.imageNames = imageNames
        self.assistantImagePlacements = assistantImagePlacements
        self.deliveryState = deliveryState
        self.sourceEntryId = sourceEntryId
        self.sourceBranchable = sourceBranchable
    }
}

private struct PendingPrompt {
    var itemId: UUID
    var display: String
    var imageNames: [String]
    var text: String
    var attachments: [PromptAttachment]
    var images: [PromptImage]
    var branch: ConversationBranchDraft? = nil
    var draftText: String = ""
    var draftClips: [DraftClip] = []
    var draftImages: [DraftImage] = []
}

struct ConversationBranchDraft: Equatable {
    var targetEntryID: String
    var originalLeafID: String
    var sourceItemID: UUID
    var title: String
    var suspendedDraft: String
    var suspendedClips: [DraftClip]
    var suspendedImages: [DraftImage]
}

private struct TranscriptEnvelope: Codable, @unchecked Sendable {
    var version: Int = 1
    var sessionId: String
    var selectedLeafId: String?
    var items: [ChatItem]
    var richItems: [ChatItem]? = nil
}

private struct TranscriptLoadResult: @unchecked Sendable {
    var items: [ChatItem]
    var richItems: [ChatItem]
}

struct QueuedUserMessage: Identifiable, Equatable {
    var id: UUID
    var text: String
    var imageNames: [String]
}

enum SessionRuntimeRole: Equatable {
    case main
    case side

    var restoresSavedTranscript: Bool { self == .main }
    var persistsAsMain: Bool { self == .main }
    var persistsWorkspaceRegistry: Bool { self == .main }

    func controlFile(runtimeID: UUID) -> URL {
        switch self {
        case .main:
            return OverlayPaths.controlFile
        case .side:
            return OverlayPaths.sideControlFile(runtimeID: runtimeID)
        }
    }
}

@Observable
final class ChatStore {
    var items: [ChatItem] = []
    var draft: String = "" {
        didSet {
            let signature = PromptPalette.activeToken(in: draft)?.trigger.signature ?? ""
            if signature != lastPaletteSignature {
                lastPaletteSignature = signature
                paletteSuppressed = false
                slashHighlight = 0
            }
            syncOverlayChrome()
        }
    }
    var composerChromeHeight: CGFloat = OverlayMetrics.minHeight
    var slashMenuPresented = false
    var slashPaletteChromeHeight: CGFloat = 0
    var isStartingSession = false
    var isConnected = false
    var status: String = "starting"
    var focusTick = 0
    var streamingAssistantId: UUID?
    private var pendingAssistantChunk = ""
    private var forceNewAssistantRow = false
    private var pendingThoughtChunk = ""
    private var streamFlushQueued = false
    private var lastStreamFlushUptime: TimeInterval = 0
    var streamingThoughtId: UUID?
    var turnStartedAt: Date?
    var lastTurnDuration: TimeInterval = 0
    var showAvatarPicker = false {
        didSet { syncOverlayChrome() }
    }
    var isBusy = false {
        didSet {
            syncOverlayChrome()
            onActivityChanged?(hasActiveWork)
        }
    }
    var selectedAvatarFile = AvatarSelection.file
    var transcriptWide = UserDefaults.standard.bool(forKey: "bubble.transcript.wide")
    var overlayPinned = UserDefaults.standard.bool(forKey: "bubble.overlay.pinned")
    var filePreview: FilePreviewDocument?
    var workspaceStage: WorkspaceStage?
    var workspacePaneItems: [ChatItem] = []
    var workspacePaneStreamingAssistantId: UUID?
    var workspacePaneStreamingThoughtId: UUID?
    var workspacePaneScrollToken = 0
    var workspacePaneLoadState: WorkspacePaneLoadState = .idle
    var workspacePanePresentationPhase: WorkspacePanePresentationPhase = .ready
    var workspacePaneCoverVisible = true
    private var workspacePaneRenderReady = true
    private var workspacePaneRenderGeneration = 0
    @ObservationIgnored private var workspacePaneWarmupTask: Task<Void, Never>?
    var sideStageChromeVisible = false
    var visibleScreenWidth: CGFloat = 1512
    var slashCommands: [SlashCommand] = SlashCommand.builtIn
    var skills: [PiSkill] = []
    var prompts: [PiPrompt] = []
    var sessions: [PiSessionInfo] = []
    var workspaceFiles: [WorkspaceFile] = []
    var currentModelId: String? = BubbleConfig.load().modelIdentity
    var thinkingLevels: [String] = BubbleConfig.defaultThinkingLevels
    var currentThinking: String? = BubbleConfig.load().thinking
    var installedApps: [MacApp] = []
    var macEpoch = 0
    var slashHighlight = 0
    var resumeDestination = ResumeDestinationState()
    var onHideOverlay: (() -> Void)?
    var onCreateSideSession: (() -> Void)?
    var onResumeInSideSession: ((String) -> Int?)?
    var onSessionIdentityChanged: (() -> Void)?
    var onActivityChanged: ((Bool) -> Void)?
    var onTranscriptUpdated: (() -> Void)?
    var onWorkspacePanePresentationRequested: (() -> Void)?
    var onSideStageChromePresentationRequested: (() -> Void)?
    var onSideStageChromeDismissalRequested: (() -> Void)?
    var onSideStageChromeInvalidated: (() -> Void)?
    var workspaceState = WorkspaceStoreFile()
    var draftClips: [DraftClip] = [] {
        didSet { syncOverlayChrome() }
    }
    var draftImages: [DraftImage] = [] {
        didSet { syncOverlayChrome() }
    }
    var childBusy = false {
        didSet { onActivityChanged?(hasActiveWork) }
    }
    var streamUISuspended = true
    var composerFocusSuspended = true
    var transcriptRevision: UInt64 = 0
    var transcriptHistoryTurnCapacity = TranscriptHistoryWindow.configuredInitialCapacity
    @ObservationIgnored private var resumeActionGeneration = 0
    var conversationTree: ConversationTreeSnapshot?
    var branchDraft: ConversationBranchDraft? {
        didSet { syncOverlayChrome() }
    }
    var isSwitchingBranch = false
    private var paletteSuppressed = false
    private var lastPaletteSignature = ""
    private let control: WorkspaceControlServer
    private var childSessionId: String?
    private var childSessionIds: Set<String> = []
    private var workspaceRunGeneration = 0
    private var hushMainAssistant = false
    private var injectSpoke = false
    private var mountSkillNames: [String: [String]] = [:]
    private var childAssistant = ""
    private var childChanged: [String] = []
    private var pendingInjection: WorkspaceBrief?
    private var injecting = false

    private var hasActiveWork: Bool { isBusy || childBusy }
    private var pendingChildSteer: WorkspaceBrief?
    private var pendingPrompts: [PendingPrompt] = []
    private var steeringMessageIds: Set<UUID> = []
    private var runNonce = 0
    private var isInstalling = false
    private var activeBranchPrompt: PendingPrompt?
    private var activeBranchNavigationSucceeded = false

    var queuedMessages: [QueuedUserMessage] {
        pendingPrompts.map {
            QueuedUserMessage(id: $0.itemId, text: $0.display, imageNames: $0.imageNames)
        }
    }

    func toggleAvatarPicker() {
        showAvatarPicker.toggle()
        requestFocus()
    }

    func selectAvatar(_ file: String) {
        selectedAvatarFile = file
        AvatarSelection.file = file
        showAvatarPicker = false
        requestFocus()
    }

    func setTranscriptWidth(_ wide: Bool) {
        transcriptWide = wide
        UserDefaults.standard.set(transcriptWide, forKey: "bubble.transcript.wide")
    }

    func toggleOverlayPin() {
        overlayPinned.toggle()
        UserDefaults.standard.set(overlayPinned, forKey: "bubble.overlay.pinned")
        requestFocus()
    }

    func openFilePreview(_ raw: String, fromWorkspacePane: Bool = false) {
        let path = PreviewFiles.resolve(
            raw,
            workspace: OverlayPaths.workspace.path,
            extraRoots: filePreviewSearchRoots()
        )
        if filePreview?.path == path {
            if workspaceStage == nil {
                closeSideStage()
            } else {
                filePreview = nil
            }
            return
        }
        let wasPresented = sideStagePresented
        if !SideStagePolicy.keepWorkspaceWhenOpeningFilePreview(fromWorkspacePane: fromWorkspacePane) {
            clearWorkspaceStage(keepingItems: false)
        }
        filePreview = PreviewFiles.load(path: path)
        applySideStageChromeOnOpen(wasPresented: wasPresented)
    }

    private func filePreviewSearchRoots() -> [String] {
        var seen = Set<String>()
        var roots: [String] = []
        func add(_ path: String) {
            let standardized = (path as NSString).standardizingPath
            guard !standardized.isEmpty, seen.insert(standardized).inserted else { return }
            roots.append(standardized)
        }
        for mount in workspaceState.mounts {
            add(mount.path)
        }
        add(OverlayPaths.workspaceSkillsDirectory.path)
        add(OverlayPaths.piAgent.path)
        add(OverlayPaths.userAgentsSkills.path)
        for item in items {
            if let path = item.workspacePath {
                add(path)
            }
            for changed in item.workspaceChangedPaths ?? [] {
                add((changed as NSString).deletingLastPathComponent)
            }
        }
        return roots
    }

    func closeFilePreview() {
        if workspaceStage == nil {
            closeSideStage()
            return
        }
        filePreview = nil
    }

    func closeSideStage(animated: Bool = true) {
        if animated, SideStageChromePolicy.shouldFadeOutBeforeCollapse(
            chromeVisible: sideStageChromeVisible,
            presented: sideStagePresented
        ) {
            sideStageChromeVisible = false
            onSideStageChromeDismissalRequested?()
            return
        }
        collapseSideStage()
    }

    func collapseSideStage() {
        onSideStageChromeInvalidated?()
        filePreview = nil
        clearWorkspaceStage(keepingItems: false)
        sideStageChromeVisible = false
    }

    func revealSideStageChrome() {
        guard sideStagePresented else { return }
        sideStageChromeVisible = true
    }

    func returnToWorkspaceStage() {
        filePreview = nil
        revealWorkspacePaneContent()
        uncoverWorkspacePane()
        workspacePaneScrollToken += 1
    }

    @discardableResult
    func handleSideStageEscape() -> Bool {
        switch SideStagePolicy.escapeAction(
            showingFilePreview: filePreview != nil,
            workspaceStacked: workspaceStage != nil,
            showingWorkspace: workspaceStage != nil
        ) {
        case .returnToWorkspace:
            returnToWorkspaceStage()
            return true
        case .closeStage:
            closeSideStage()
            return true
        case .ignore:
            return false
        }
    }

    var sideStagePresented: Bool {
        SideStagePolicy.isPresented(
            showingFilePreview: filePreview != nil,
            showingWorkspace: workspaceStage != nil
        )
    }

    var showsWorkspaceTranscript: Bool {
        SideStagePolicy.showsWorkspaceTranscript(
            showingFilePreview: filePreview != nil,
            showingWorkspace: workspaceStage != nil
        )
    }

    var canReturnToWorkspace: Bool {
        SideStagePolicy.canReturnToWorkspace(
            showingFilePreview: filePreview != nil,
            workspaceStacked: workspaceStage != nil
        )
    }

    func toggleWorkspaceStage(from item: ChatItem) {
        if SideStagePolicy.shouldToggleClosed(
            openCardId: workspaceStage?.cardId,
            tappedCardId: item.id
        ) {
            closeSideStage()
            return
        }
        openWorkspaceStage(from: item)
    }

    func openActiveWorkspaceStage() {
        guard let brief = activeWorkspaceBrief, brief.isActive else { return }
        if let item = items.last(where: {
            $0.kind == .workspaceRun && $0.workspacePath == brief.path
        }) {
            if workspaceStage?.cardId == item.id, filePreview == nil {
                return
            }
            openWorkspaceStage(from: item)
        }
    }

    func openWorkspaceStage(from item: ChatItem) {
        let wasPresented = sideStagePresented
        let opensSideStage = workspaceStage == nil && filePreview == nil
        let changesWorkspace = workspaceStage?.cardId != item.id
        filePreview = nil
        if opensSideStage || changesWorkspace {
            workspacePanePresentationPhase = .placeholder
            workspacePaneCoverVisible = true
        }
        let status = item.workspaceStatus
        let follow = SideStagePolicy.followLatest(status: status)
        let sessionId = follow
            ? SideStagePolicy.preferredWorkspaceSessionId(
                cardSessionId: item.workspaceSessionId,
                mountedSessionId: WorkspaceRegistry.sessionId(
                    forMountPath: item.workspacePath,
                    in: workspaceState
                )
            )
            : item.workspaceSessionId
        let previousSessionId = workspaceStage?.sessionId
        let previousCardId = workspaceStage?.cardId
        let cachedRows = sessionId.flatMap { workspacePaneRowsBySession[$0] }
        let cachedRunRows = item.workspaceRunId.flatMap { workspacePaneRowsByRun[$0] }
        let selectedAnchorIsCached = item.workspaceAnchorEntryId.map { anchor in
            cachedRows?.contains(where: { $0.sourceEntryId == anchor }) == true
        } ?? false
        let sessionIsLive = childBusy && activeWorkspaceBrief?.path == item.workspacePath
        let isLive = sessionIsLive
            && item.workspaceRunId?.isEmpty == false
            && item.workspaceRunId == activeWorkspaceBrief?.runId
        let cacheIsFresh = sessionId.map {
            cachedRows != nil
                && (!workspacePaneInvalidatedSessionIds.contains($0)
                    || (sessionIsLive && !isLive && selectedAnchorIsCached))
        } ?? false
        let hasCurrentRows = previousSessionId == sessionId
            && !workspacePaneItems.isEmpty
            && workspacePaneLoadState == .ready
        let seed = SideStagePolicy.paneSeed(.init(
            currentSessionId: previousSessionId,
            nextSessionId: sessionId,
            currentCardId: previousCardId,
            nextCardId: item.id,
            hasCurrentRows: hasCurrentRows,
            hasRunRows: cachedRunRows != nil,
            cacheIsFresh: cacheIsFresh,
            selectedAnchorIsCached: selectedAnchorIsCached,
            isLive: isLive
        ))
        workspaceStage = WorkspaceStage(
            path: item.workspacePath ?? "",
            name: item.workspaceName ?? item.text,
            runId: item.workspaceRunId,
            sessionId: sessionId,
            cardId: item.id,
            followLatest: follow,
            anchorEntryId: item.workspaceAnchorEntryId
        )
        workspacePaneStreamingAssistantId = nil
        workspacePaneStreamingThoughtId = nil
        switch seed {
        case .current:
            workspacePaneLoadState = .ready
            break
        case .run:
            workspacePaneItems = cachedRunRows ?? fallbackWorkspacePaneItems(card: item)
            workspacePaneLoadState = isLive ? .fallback : .ready
        case .cached:
            workspacePaneItems = cachedRows ?? []
            workspacePaneLoadState = .ready
        case .card:
            workspacePaneItems = fallbackWorkspacePaneItems(card: item)
            workspacePaneLoadState = .fallback
            if isLive, let runId = item.workspaceRunId, !runId.isEmpty {
                cacheWorkspaceRunRows(workspacePaneItems, runId: runId)
            }
        case .loading:
            workspacePaneItems = [
                ChatItem(kind: .system, text: Self.workspacePaneLoadingText)
            ]
            workspacePaneLoadState = .loading
        }
        prewarmWorkspacePaneRendering(workspacePaneItems)
        workspacePaneLoadGeneration += 1
        let generation = workspacePaneLoadGeneration
        workspacePaneScrollToken += 1
        if seed == .loading, let sessionId, !sessionId.isEmpty {
            let path = item.workspacePath ?? ""
            startWorkspacePaneLoad(
                from: item,
                path: path,
                sessionId: sessionId,
                generation: generation
            )
        }
        applySideStageChromeOnOpen(wasPresented: wasPresented)
        if workspacePanePresentationPhase == .placeholder {
            onWorkspacePanePresentationRequested?()
        }
    }

    private func applySideStageChromeOnOpen(wasPresented: Bool) {
        if SideStageChromePolicy.opensHidden(wasPresented: wasPresented) {
            sideStageChromeVisible = false
            onSideStageChromePresentationRequested?()
            return
        }
        onSideStageChromeInvalidated?()
        sideStageChromeVisible = true
    }

    private func clearWorkspaceStage(keepingItems: Bool) {
        workspacePaneWarmupTask?.cancel()
        workspacePaneWarmupTask = nil
        workspacePaneRenderGeneration += 1
        workspacePaneRenderReady = true
        workspaceStage = nil
        workspacePanePresentationPhase = .ready
        workspacePaneCoverVisible = true
        if !keepingItems {
            workspacePaneItems = []
            workspacePaneLoadState = .idle
            workspacePaneStreamingAssistantId = nil
            workspacePaneStreamingThoughtId = nil
        }
    }

    func revealWorkspacePaneContent() {
        guard workspaceStage != nil else { return }
        if SideStagePresentationPolicy.waitsForContent(
            loadState: workspacePaneLoadState,
            renderReady: workspacePaneRenderReady
        ) {
            workspacePanePresentationPhase = .waitingForContent
            workspacePaneCoverVisible = true
            return
        }
        workspacePanePresentationPhase = .ready
    }

    func uncoverWorkspacePane() {
        guard workspaceStage != nil, workspacePanePresentationPhase == .ready else { return }
        workspacePaneCoverVisible = false
    }

    private func workspacePaneContentDidBecomeAvailable() {
        guard workspacePanePresentationPhase == .waitingForContent,
              !SideStagePresentationPolicy.waitsForContent(
                  loadState: workspacePaneLoadState,
                  renderReady: workspacePaneRenderReady
              ) else { return }
        workspacePanePresentationPhase = .placeholder
        onWorkspacePanePresentationRequested?()
    }

    private func fallbackWorkspacePaneItems(card: ChatItem) -> [ChatItem] {
        var rows: [ChatItem] = []
        let goal = card.workspaceGoal?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !goal.isEmpty {
            rows.append(
                ChatItem(
                    kind: .user,
                    text: goal,
                    sourceEntryId: card.workspaceAnchorEntryId
                )
            )
        }
        rows.append(contentsOf: card.workspaceChildren ?? [])
        let summary = card.workspaceSummary?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !SideStagePolicy.followLatest(status: card.workspaceStatus), !summary.isEmpty {
            let hasAssistant = rows.contains { $0.kind == .assistant }
            if !hasAssistant {
                rows.append(ChatItem(kind: .assistant, text: summary))
            }
        }
        return rows
    }

    private func loadWorkspacePane(
        from item: ChatItem,
        path: String,
        sessionId: String,
        generation: Int
    ) async {
        guard !sessionId.isEmpty, !path.isEmpty else {
            failWorkspacePaneLoad(for: item, generation: generation)
            return
        }
        guard workspacePaneRequestIsCurrent(cardId: item.id, generation: generation) else { return }
        let cwd = URL(fileURLWithPath: path)
        let local = await Task.detached(priority: .userInitiated) {
            guard let snapshot = PiSessions.conversationTree(sessionId: sessionId, cwd: cwd) else {
                return nil as (ConversationTreeSnapshot, [ConversationTranscriptRecord])?
            }
            return (snapshot, snapshot.transcript)
        }.value
        guard workspacePaneRequestIsCurrent(cardId: item.id, generation: generation) else { return }
        if let (localSnapshot, localTranscript) = local {
            applyWorkspaceTree(
                localSnapshot,
                path: path,
                sessionId: sessionId,
                cardId: item.id,
                goal: item.workspaceGoal ?? "",
                transcript: localTranscript
            )
            OverlayLog.write("workspace pane loaded local session \(sessionId)")
            return
        }
        if !isConnected {
            await connect()
        }
        guard workspacePaneRequestIsCurrent(cardId: item.id, generation: generation) else { return }
        if SideStagePolicy.shouldAttachSession(
            sessionId: sessionId,
            liveSessionIds: childSessionIds.union(workspacePaneAttachedSessionIds),
            childBusy: childBusy
        ) {
            do {
                guard try await client.attach(sessionId, cwd: cwd) else {
                    failWorkspacePaneLoad(for: item, generation: generation)
                    return
                }
                workspacePaneAttachedSessionIds.insert(sessionId)
            } catch {
                failWorkspacePaneLoad(for: item, generation: generation)
                return
            }
        } else {
            OverlayLog.write("workspace pane skip attach \(sessionId)")
        }
        guard workspacePaneRequestIsCurrent(cardId: item.id, generation: generation) else { return }
        let snapshot: ConversationTreeSnapshot
        do {
            snapshot = try await client.conversationTree(sessionId: sessionId)
        } catch {
            failWorkspacePaneLoad(for: item, generation: generation)
            return
        }
        guard workspacePaneRequestIsCurrent(cardId: item.id, generation: generation) else { return }
        applyWorkspaceTree(
            snapshot,
            path: path,
            sessionId: sessionId,
            cardId: item.id,
            goal: item.workspaceGoal ?? ""
        )
    }

    private func startWorkspacePaneLoad(
        from item: ChatItem,
        path: String,
        sessionId: String,
        generation: Int
    ) {
        Task { @MainActor in
            await loadWorkspacePane(
                from: item,
                path: path,
                sessionId: sessionId,
                generation: generation
            )
        }
        Task { @MainActor in
            let delay = SideStagePolicy.workspaceLoadFallbackDelay
            do {
                try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            } catch {
                return
            }
            guard SideStagePolicy.shouldFallbackWorkspaceLoad(elapsed: delay) else { return }
            settleSlowWorkspacePaneLoad(for: item, generation: generation)
        }
    }

    private func settleSlowWorkspacePaneLoad(for item: ChatItem, generation: Int) {
        guard workspacePaneRequestIsCurrent(cardId: item.id, generation: generation),
              workspacePaneLoadState == .loading else { return }
        workspacePaneItems = fallbackWorkspacePaneItems(card: item)
        workspacePaneLoadState = .fallback
        workspacePaneContentDidBecomeAvailable()
        workspacePaneScrollToken += 1
        OverlayLog.write("workspace pane used local fallback after \(SideStagePolicy.workspaceLoadFallbackDelay)s")
    }

    private func workspacePaneRequestIsCurrent(cardId: UUID, generation: Int) -> Bool {
        generation == workspacePaneLoadGeneration && workspaceStage?.cardId == cardId
    }

    private func failWorkspacePaneLoad(for item: ChatItem, generation: Int) {
        guard workspacePaneRequestIsCurrent(cardId: item.id, generation: generation) else { return }
        workspacePaneItems = fallbackWorkspacePaneItems(card: item)
        workspacePaneLoadState = .failed
        workspacePaneContentDidBecomeAvailable()
        workspacePaneScrollToken += 1
    }

    private func applyWorkspaceTree(
        _ snapshot: ConversationTreeSnapshot,
        path: String,
        sessionId: String,
        cardId: UUID,
        goal: String,
        transcript: [ConversationTranscriptRecord]? = nil
    ) {
        cacheWorkspacePaneRows(workspacePaneItems)
        let turns = snapshot.activePath.filter(\.isUserMessage).map {
            ($0.id, ConversationTreeSnapshot.displayUserText($0.text))
        }
        let ordered = items.filter { $0.kind == .workspaceRun && $0.workspacePath == path }
        let cardIndex = ordered.firstIndex(where: { $0.id == cardId })
        let stored = items.first(where: { $0.id == cardId })?.workspaceAnchorEntryId
            ?? workspaceStage?.anchorEntryId
        let anchor = SideStagePolicy.anchorEntryId(
            stored: stored,
            goal: goal,
            cardIndex: cardIndex,
            turns: turns
        )
        if let index = items.firstIndex(where: { $0.id == cardId }) {
            items[index].workspaceAnchorEntryId = anchor
            items[index].workspaceSessionId = sessionId
            persist()
        }
        if var stage = workspaceStage, stage.cardId == cardId {
            stage.anchorEntryId = anchor
            workspaceStage = stage
        }
        if childBusy, workspacePaneIsCurrent(), SideStagePolicy.followLatest(
            status: items.first(where: { $0.id == cardId })?.workspaceStatus
        ) {
            return
        }
        let projected = (transcript ?? snapshot.transcript).map { record in
            var projected = Self.chatItem(record)
            if let prior = workspacePaneRichRows[Self.richKey(entryID: record.entryID, kind: projected.kind)] {
                var rich = prior
                rich.text = projected.text
                rich.toolStatus = projected.toolStatus ?? rich.toolStatus
                rich.toolKind = projected.toolKind ?? rich.toolKind
                rich.toolInput = projected.toolInput ?? rich.toolInput
                rich.toolOutput = projected.toolOutput ?? rich.toolOutput
                rich.sourceEntryId = record.entryID
                projected = rich
            }
            return projected
        }
        let turnRows = projected.map {
            WorkspaceTurnRow(
                id: $0.id.uuidString,
                sourceEntryId: $0.sourceEntryId,
                kind: Self.workspaceTurnRowKind($0.kind)
            )
        }
        let card = items.first(where: { $0.id == cardId })
        let followsLatest = SideStagePolicy.followLatest(status: card?.workspaceStatus)
        let visibleRows: [ChatItem]
        if !followsLatest {
            if let range = SideStagePolicy.runRange(anchorEntryId: anchor, rows: turnRows) {
                visibleRows = Array(projected[range])
            } else if let card {
                visibleRows = fallbackWorkspacePaneItems(card: card)
            } else {
                visibleRows = []
            }
        } else {
            visibleRows = projected
        }
        workspacePaneItems = visibleRows
        prewarmWorkspacePaneRendering(visibleRows)
        if childBusy {
            workspacePaneRowsBySession[sessionId] = visibleRows
            workspacePaneLoadState = .ready
        } else {
            workspacePaneRowsBySession[sessionId] = visibleRows
            workspacePaneInvalidatedSessionIds.remove(sessionId)
            workspacePaneLoadState = .ready
        }
        workspacePaneContentDidBecomeAvailable()
        if !followsLatest,
           let runId = card?.workspaceRunId,
           !runId.isEmpty {
            cacheWorkspaceRunRows(visibleRows, runId: runId)
        }
        cacheWorkspacePaneRows(projected)
        workspacePaneScrollToken += 1
    }

    private func prewarmWorkspacePaneRendering(_ rows: [ChatItem]) {
        workspacePaneWarmupTask?.cancel()
        workspacePaneWarmupTask = nil
        let streamingID = workspacePaneStreamingAssistantId
        let items = rows.compactMap { item -> WorkspaceTranscriptWarmupItem? in
            guard item.kind == .assistant,
                  item.id != streamingID,
                  !item.text.isEmpty else { return nil }
            return WorkspaceTranscriptWarmupItem(
                identity: item.id.uuidString,
                text: item.text
            )
        }
        workspacePaneRenderGeneration += 1
        let generation = workspacePaneRenderGeneration
        guard !items.isEmpty else {
            workspacePaneRenderReady = true
            workspacePaneContentDidBecomeAvailable()
            return
        }
        workspacePaneRenderReady = false
        let warmupTask = Task.detached(priority: .userInitiated) {
            for item in items {
                guard !Task.isCancelled else { return }
                for edge in WorkspaceTranscriptChunker.visibleEdges(
                    item.text,
                    identity: item.identity
                ) {
                    MessagePart.prewarmDisplay(edge)
                }
            }
            WorkspaceTranscriptWarmup.prepare(items)
        }
        workspacePaneWarmupTask = warmupTask
        Task { @MainActor [weak self] in
            await warmupTask.value
            guard let self,
                  generation == self.workspacePaneRenderGeneration,
                  self.workspaceStage != nil else { return }
            self.workspacePaneWarmupTask = nil
            self.workspacePaneRenderReady = true
            self.workspacePaneContentDidBecomeAvailable()
        }
    }

    private func cacheWorkspacePaneRows(_ rows: [ChatItem]) {
        for item in rows {
            guard let key = Self.richKey(item) else { continue }
            workspacePaneRichRows[key] = item
        }
        if let sessionId = workspaceStage?.sessionId,
           workspacePaneRowsBySession[sessionId] != nil,
           workspacePaneLoadState == .ready,
           !workspacePaneInvalidatedSessionIds.contains(sessionId) {
            workspacePaneRowsBySession[sessionId] = workspacePaneItems
        }
    }

    private static func workspaceTurnRowKind(_ kind: ChatItem.Kind) -> WorkspaceTurnRowKind {
        switch kind {
        case .user: .user
        case .assistant: .assistant
        case .thought: .thought
        case .tool: .tool
        case .system, .workspaceRun: .other
        }
    }

    private func invalidateWorkspacePaneSession(_ sessionId: String) {
        guard !sessionId.isEmpty else { return }
        workspacePaneInvalidatedSessionIds.insert(sessionId)
        if workspaceStage?.sessionId == sessionId, workspacePaneLoadState == .ready {
            workspacePaneLoadState = .fallback
        }
    }

    private func captureWorkspaceAnchor(
        sessionId: String,
        goal: String,
        path: String,
        generation: Int,
        runId: String
    ) async {
        guard WorkspaceRunLifecyclePolicy.acceptsCompletion(
            expectedGeneration: generation,
            currentGeneration: workspaceRunGeneration,
            expectedRunId: runId,
            activeRunId: workspaceState.active?.runId
        ) else { return }
        guard let snapshot = try? await client.conversationTree(sessionId: sessionId) else { return }
        guard WorkspaceRunLifecyclePolicy.acceptsCompletion(
            expectedGeneration: generation,
            currentGeneration: workspaceRunGeneration,
            expectedRunId: runId,
            activeRunId: workspaceState.active?.runId
        ) else { return }
        let turns = snapshot.activePath.filter(\.isUserMessage).map {
            ($0.id, ConversationTreeSnapshot.displayUserText($0.text))
        }
        let ordered = items.filter { $0.kind == .workspaceRun && $0.workspacePath == path }
        guard let card = ordered.last else { return }
        let cardIndex = max(0, ordered.count - 1)
        let anchor = SideStagePolicy.anchorEntryId(
            stored: card.workspaceAnchorEntryId,
            goal: goal,
            cardIndex: cardIndex,
            turns: turns
        )
        if let index = items.firstIndex(where: { $0.id == card.id }) {
            items[index].workspaceAnchorEntryId = anchor
            items[index].workspaceSessionId = sessionId
            persist()
        }
        if workspaceStage?.cardId == card.id {
            workspaceStage?.sessionId = sessionId
            workspaceStage?.anchorEntryId = anchor
            applyWorkspaceTree(
                snapshot,
                path: path,
                sessionId: sessionId,
                cardId: card.id,
                goal: goal
            )
        }
    }

    private func workspacePaneIsCurrent(
        path: String? = nil,
        sessionId: String? = nil,
        runId: String? = nil
    ) -> Bool {
        guard !streamUISuspended else { return false }
        guard let stage = workspaceStage else { return false }
        guard SideStagePolicy.acceptsWorkspaceUpdate(
            stageRunId: stage.runId,
            incomingRunId: runId
        ) else { return false }
        if let sessionId, !sessionId.isEmpty, let current = stage.sessionId, !current.isEmpty {
            guard current == sessionId else { return false }
        }
        if let path, !path.isEmpty {
            guard stage.path == path else { return false }
        }
        return true
    }

    private func appendWorkspacePaneAssistant(
        _ raw: String,
        path: String?,
        sessionId: String?,
        runId: String?,
        forceNew: Bool = false
    ) {
        guard let runId, !runId.isEmpty else { return }
        var rows = workspaceRunBuffer(runId: runId)
        if !forceNew, let index = TranscriptStream.resumeAssistantIndex(kinds: rows.map(\.kind.rawValue)) {
            rows[index].text = Self.stripDiagnostics(rows[index].text + raw)
        } else {
            let cleaned = Self.stripDiagnostics(raw)
            guard !cleaned.isEmpty else { return }
            rows.append(ChatItem(kind: .assistant, text: cleaned))
        }
        cacheWorkspaceRunRows(rows, runId: runId)
        guard workspacePaneIsCurrent(path: path, sessionId: sessionId, runId: runId) else { return }
        workspacePaneItems = rows
        workspacePaneStreamingAssistantId = rows.last(where: { $0.kind == .assistant })?.id
    }

    private func appendWorkspacePaneAssistantImage(
        _ image: AssistantMessageImage,
        path: String?,
        sessionId: String?,
        runId: String?,
        forceNew: Bool = false
    ) {
        guard let runId, !runId.isEmpty,
              let name = BubbleImages.save(image.data, mimeType: image.mimeType) else { return }
        var rows = workspaceRunBuffer(runId: runId)
        if !forceNew, let index = TranscriptStream.resumeAssistantIndex(kinds: rows.map(\.kind.rawValue)) {
            appendAssistantImageName(name, to: &rows[index])
        } else {
            rows.append(ChatItem(
                kind: .assistant,
                text: "",
                imageNames: [name],
                assistantImagePlacements: [AssistantImagePlacement(name: name, textOffset: 0)]
            ))
        }
        cacheWorkspaceRunRows(rows, runId: runId)
        guard workspacePaneIsCurrent(path: path, sessionId: sessionId, runId: runId) else { return }
        workspacePaneItems = rows
        workspacePaneStreamingAssistantId = rows.last(where: { $0.kind == .assistant })?.id
    }

    private func workspaceRunBuffer(runId: String) -> [ChatItem] {
        if let rows = workspacePaneRowsByRun[runId] { return rows }
        guard let card = items.last(where: {
            $0.kind == .workspaceRun && $0.workspaceRunId == runId
        }) else { return [] }
        return fallbackWorkspacePaneItems(card: card)
    }

    private func cacheWorkspaceRunRows(_ rows: [ChatItem], runId: String) {
        workspacePaneRowsByRun[runId] = rows
        workspacePaneRunCacheOrder.removeAll { $0 == runId }
        workspacePaneRunCacheOrder.append(runId)
        while workspacePaneRunCacheOrder.count > Self.workspacePaneRunCacheLimit {
            let evicted = workspacePaneRunCacheOrder.removeFirst()
            workspacePaneRowsByRun.removeValue(forKey: evicted)
        }
    }

    private func removeWorkspaceRunRows(runId: String) {
        workspacePaneRowsByRun.removeValue(forKey: runId)
        workspacePaneRunCacheOrder.removeAll { $0 == runId }
    }

    private func appendWorkspacePaneThought(
        _ raw: String,
        path: String?,
        sessionId: String?,
        runId: String?
    ) {
        guard let runId, !runId.isEmpty else { return }
        var rows = workspaceRunBuffer(runId: runId)
        if TranscriptStream.shouldMergeThought(previousKind: rows.last?.kind.rawValue),
           let index = rows.indices.last {
            rows[index].text = Self.stripDiagnostics(rows[index].text + raw)
        } else {
            let cleaned = Self.stripDiagnostics(raw)
            guard !cleaned.isEmpty else { return }
            rows.append(ChatItem(kind: .thought, text: cleaned))
        }
        cacheWorkspaceRunRows(rows, runId: runId)
        guard workspacePaneIsCurrent(path: path, sessionId: sessionId, runId: runId) else { return }
        workspacePaneItems = rows
        workspacePaneStreamingThoughtId = rows.last(where: { $0.kind == .thought })?.id
    }

    private func upsertWorkspacePaneTool(
        _ update: [String: Any],
        isUpdate: Bool,
        path: String?,
        sessionId: String?,
        runId: String?
    ) {
        guard let runId, !runId.isEmpty else { return }
        var rows = workspaceRunBuffer(runId: runId)
        let callId = update.string("toolCallId") ?? UUID().uuidString
        let title = update.string("title") ?? update.string("kind") ?? "tool"
        let status = update.string("status") ?? "pending"
        let payload = extractToolPayload(update)
        let imageNames = persistedImageNames(payload.images)
        if let index = rows.lastIndex(where: { $0.kind == .tool && $0.toolId == callId }) {
            rows[index].text = title
            rows[index].toolStatus = status
            if let input = payload.input { rows[index].toolInput = input }
            if let output = payload.output { rows[index].toolOutput = output }
            mergeImageNames(imageNames, into: &rows[index])
        } else if !isUpdate || title != "tool" {
            rows.append(
                ChatItem(
                    kind: .tool,
                    text: title,
                    toolId: callId,
                    toolStatus: status,
                    toolInput: payload.input,
                    toolOutput: payload.output,
                    imageNames: imageNames
                )
            )
        }
        cacheWorkspaceRunRows(rows, runId: runId)
        guard workspacePaneIsCurrent(path: path, sessionId: sessionId, runId: runId) else { return }
        workspacePaneStreamingAssistantId = nil
        workspacePaneStreamingThoughtId = nil
        workspacePaneItems = rows
    }

    let runtimeID: UUID
    let client: AcpClient
    let transcriptPlanner = TranscriptRenderPlanner()
    private let runtimeRole: SessionRuntimeRole
    private static let catalogRefreshQueue = DispatchQueue(
        label: "local.bubble.catalog-refresh",
        qos: .userInitiated,
        autoreleaseFrequency: .workItem
    )
    private static let transcriptPersistQueue = DispatchQueue(
        label: "local.bubble.transcript-persist",
        qos: .utility,
        autoreleaseFrequency: .workItem
    )
    private static let transcriptWarmupQueue = DispatchQueue(
        label: "local.bubble.transcript-warmup",
        qos: .utility,
        autoreleaseFrequency: .workItem
    )
    private static let transcriptLoadQueue = DispatchQueue(
        label: "local.bubble.transcript-load",
        qos: .userInitiated,
        autoreleaseFrequency: .workItem
    )
    private var persistWork: DispatchWorkItem?
    @ObservationIgnored private var transcriptLoadGeneration = 0
    @ObservationIgnored private var transcriptRestorePending = false
    @ObservationIgnored private var transcriptRestoreTask: Task<Void, Never>?
    private var richTranscriptRows: [String: ChatItem] = [:]
    private var mountSkillRefreshGeneration = 0
    private var workspacePaneLoadGeneration = 0
    private var workspacePaneRichRows: [String: ChatItem] = [:]
    private var workspacePaneRowsBySession: [String: [ChatItem]] = [:]
    private var workspacePaneRowsByRun: [String: [ChatItem]] = [:]
    private var workspacePaneRunCacheOrder: [String] = []
    private var workspacePaneForceNewAssistantRow = false
    private var workspacePaneAttachedSessionIds: Set<String> = []
    private var workspacePaneInvalidatedSessionIds: Set<String> = []
    private static let workspacePaneLoadingText = "Loading workspace session…"
    private static let workspacePaneRunCacheLimit = 24

    var isTranscriptRestorePending: Bool { transcriptRestorePending }

    init(
        runtimeID: UUID = UUID(),
        runtimeRole: SessionRuntimeRole = .main,
        initialSessionID: String? = nil
    ) {
        self.runtimeID = runtimeID
        self.runtimeRole = runtimeRole
        let controlFile = runtimeRole.controlFile(runtimeID: runtimeID)
        client = AcpClient(controlFile: controlFile, initialSessionID: initialSessionID)
        control = WorkspaceControlServer(controlFile: controlFile)
        OverlayPaths.bootstrap()
        items = []
        let restoredSessionID = initialSessionID
            ?? (runtimeRole.restoresSavedTranscript ? PiSessions.currentId() : nil)
        workspaceState = WorkspaceRegistry.load(from: OverlayPaths.mountsFile)
        if runtimeRole.persistsWorkspaceRegistry, workspaceState.active?.isActive == true {
            workspaceState.active = nil
            try? WorkspaceRegistry.save(workspaceState, to: OverlayPaths.mountsFile)
        } else if !runtimeRole.persistsWorkspaceRegistry {
            workspaceState.active = nil
        }
        refreshMountSkills()
        refreshCatalog()
        client.onUpdate = { [weak self] update in
            guard update.shouldDeliverToTranscript else { return }
            DispatchQueue.main.async {
                self?.routeUpdate(update.sessionId, update.data)
                self?.onTranscriptUpdated?()
            }
        }
        client.onLog = { text in
            OverlayLog.write("pi: \(text)")
        }
        client.onExit = { [weak self] code in
            DispatchQueue.main.async {
                self?.isConnected = false
                self?.isBusy = false
                self?.workspacePaneAttachedSessionIds.removeAll()
                self?.status = "pi-acp exited (\(code))"
            }
        }
        client.onConfigChange = { [weak self] in
            DispatchQueue.main.async {
                self?.syncSessionConfig()
            }
        }
        control.handler = { [weak self] method, params in
            try await self?.handleWorkspaceControl(method, params) ?? [:]
        }
        control.start()
        if let restoredSessionID {
            restoreTranscriptInBackground(sessionID: restoredSessionID)
        }
    }

    func prepareToQuit() {
        finishPendingTranscriptRestore()
        closeSideStage(animated: false)
        WorkspaceRegistry.interruptActive(in: &workspaceState)
        if runtimeRole.persistsWorkspaceRegistry {
            persistWorkspaceState()
        }
        writeTranscript()
        Self.transcriptPersistQueue.sync {}
        control.stop()
    }

    func shutdown() {
        cancelPendingResumeAction()
        prepareToQuit()
        client.stop()
    }

    func shutdownClosedTabRuntime() {
        cancelPendingResumeAction()
        if !transcriptRestorePending {
            writeTranscript()
        }
        client.onUpdate = nil
        client.onLog = nil
        client.onExit = nil
        client.onConfigChange = nil
        control.handler = nil
        let client = client
        let control = control
        let pendingRestore = transcriptRestoreTask
        Task { @MainActor in
            await pendingRestore?.value
            DispatchQueue.global(qos: .utility).async {
                control.stop()
                client.stop()
            }
        }
    }

    func cancelPendingResumeAction() {
        resumeActionGeneration &+= 1
        resumeDestination.cancelPendingAction()
    }

    private var transcriptHistoryLowerBound: Int {
        TranscriptHistoryWindow.lowerBound(
            rows: items,
            turnCapacity: transcriptHistoryTurnCapacity,
            isUser: { $0.kind == .user }
        )
    }

    var hasEarlierTranscriptItems: Bool {
        transcriptHistoryLowerBound > 0
    }

    func loadEarlierTranscriptItems() {
        let previousLowerBound = transcriptHistoryLowerBound
        let totalTurns = items.reduce(into: 0) { count, item in
            if item.kind == .user { count += 1 }
        }
        let expanded = TranscriptHistoryWindow.expandedCapacity(
            current: transcriptHistoryTurnCapacity,
            totalTurns: totalTurns
        )
        guard expanded != transcriptHistoryTurnCapacity else { return }
        transcriptHistoryTurnCapacity = expanded
        let nextLowerBound = transcriptHistoryLowerBound
        if nextLowerBound < previousLowerBound {
            Self.prewarmTranscriptChunks(Array(items[nextLowerBound..<previousLowerBound]))
        }
    }

    var visibleItems: [ChatItem] {
        items[transcriptHistoryLowerBound...].filter { item in
            switch item.kind {
            case .assistant:
                return AssistantMessagePresentation.hasContent(
                    text: item.text,
                    imageNames: item.imageNames
                )
            case .thought:
                if item.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    return isBusy && item.id == streamingThoughtId
                }
                return true
            default:
                return true
            }
        }
    }

    var currentSessionID: String? { client.sessionId }
    var sessionTabRole: SessionTabRuntimeRole { runtimeRole == .main ? .main : .side }

    var visibleWorkspacePaneItems: [ChatItem] {
        workspacePaneItems.filter { item in
            switch item.kind {
            case .assistant:
                return AssistantMessagePresentation.hasContent(
                    text: item.text,
                    imageNames: item.imageNames
                )
            case .thought:
                if item.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    return item.id == workspacePaneStreamingThoughtId
                }
                return true
            default:
                return true
            }
        }
    }

    var isMountPalette: Bool {
        BubbleComposer.argumentQuery(command: "mounts", in: draft) != nil
    }

    var activeWorkspaceBrief: WorkspaceBrief? {
        workspaceState.active
    }

    var paletteItems: [PaletteItem] {
        if let query = BubbleComposer.argumentQuery(command: "model", in: draft) {
            return modelPaletteItems(query: query)
        }
        if let query = BubbleComposer.argumentQuery(command: "thinking", in: draft) {
            return thinkingPaletteItems(query: query)
        }
        if let query = BubbleComposer.argumentQuery(command: "open", in: draft) {
            return appPaletteItems(query: query)
        }
        if let query = BubbleComposer.argumentQuery(command: "mounts", in: draft) {
            return mountPaletteItems(query: query)
        }
        if let query = BubbleComposer.argumentQuery(command: "login", in: draft) {
            return loginPaletteItems(query: query)
        }
        if let query = BubbleComposer.argumentQuery(command: "logout", in: draft) {
            return logoutPaletteItems(query: query)
        }
        if let query = BubbleComposer.argumentQuery(command: "resume", in: draft) {
            return resumePaletteItems(query: query)
        }
        if let query = BubbleComposer.argumentQuery(command: "tree", in: draft) {
            return treePaletteItems(query: query)
        }
        guard let token = PromptPalette.activeToken(in: draft) else { return [] }
        switch token.trigger {
        case .slash(let query):
            return PromptPalette.matches(slashPaletteItems, query: query)
        case .mention(let query):
            return mentionItems(query: query)
        case .skill(let query):
            return PromptPalette.matches(skillPaletteItems(trigger: "$"), query: query)
        }
    }

    var visiblePaletteItems: [PaletteItem] {
        paletteItems
    }

    var paletteCaption: String {
        if BubbleComposer.argumentQuery(command: "model", in: draft) != nil {
            return currentModelId.map { "Models  (\($0))" } ?? "Models"
        }
        if BubbleComposer.argumentQuery(command: "thinking", in: draft) != nil {
            return currentThinking.map { "Thinking  (\($0))" } ?? "Thinking"
        }
        if isAppPalette {
            return "Apps"
        }
        if isMountPalette {
            let query = BubbleComposer.argumentQuery(command: "mounts", in: draft) ?? ""
            if WorkspaceRegistry.isPathQuery(query) {
                let path = WorkspaceRegistry.expandPath(
                    query.hasSuffix("/") || query == "~" ? query : query + "/",
                    home: OverlayPaths.home
                )
                return WorkspaceRegistry.displayPath(path, home: OverlayPaths.home.path)
            }
            return "Workspaces"
        }
        if BubbleComposer.argumentQuery(command: "login", in: draft) != nil {
            return "Providers"
        }
        if BubbleComposer.argumentQuery(command: "logout", in: draft) != nil {
            return "Signed-in providers"
        }
        if BubbleComposer.argumentQuery(command: "resume", in: draft) != nil {
            return "Sessions"
        }
        if BubbleComposer.argumentQuery(command: "tree", in: draft) != nil {
            return "Session tree"
        }
        return PromptPalette.activeToken(in: draft)?.trigger.caption ?? "Commands"
    }

    var slashMenuVisible: Bool {
        slashMenuPresented
    }

    func syncOverlayChrome() {
        let nextComposer = OverlayComposer.composerHeight(
            draft: draft,
            minHeight: OverlayMetrics.minHeight,
            avatarSize: OverlayMetrics.avatarSize,
            workspaceChip: activeWorkspaceBrief?.isActive == true,
            chipHeight: OverlayMetrics.chipHeight,
            attachmentCount: draftClips.count + draftImages.count + (branchDraft == nil ? 0 : 1),
            fieldWidth: OverlayComposer.fieldWidth(
                inputWidth: OverlayMetrics.inputWidth,
                avatarSize: OverlayMetrics.avatarSize
            ),
            fontSize: OverlayMetrics.fontSize
        )
        if OverlayComposer.chromeHeightNeedsUpdate(previous: composerChromeHeight, next: nextComposer) {
            composerChromeHeight = nextComposer
        }
        let visible = PromptTriggerPolicy.hasActiveTrigger(in: draft)
            && !paletteSuppressed
            && !showAvatarPicker
            && !isBusy
            && !visiblePaletteItems.isEmpty
        if visible != slashMenuPresented {
            slashMenuPresented = visible
        }
        let paletteHeight: CGFloat
        if visible {
            paletteHeight = OverlayPalettePolicy.chromeHeight(
                items: visiblePaletteItems.count,
                isMount: isMountPalette,
                hasSearch: isAppPalette || isMountPalette
            )
        } else {
            paletteHeight = 0
        }
        if abs(paletteHeight - slashPaletteChromeHeight) > 0.5 {
            slashPaletteChromeHeight = paletteHeight
        }
    }

    var isAppPalette: Bool {
        BubbleComposer.argumentQuery(command: "open", in: draft) != nil
    }

    var slashPaletteHeight: CGFloat {
        slashPaletteChromeHeight
    }

    private var slashPaletteItems: [PaletteItem] {
        var items: [PaletteItem] = []
        var seen = Set<String>()
        for command in slashCommands where !command.name.hasPrefix("skill:") {
            let item = paletteItem(from: command)
            if seen.insert(item.id).inserted {
                items.append(item)
            }
        }
        for prompt in prompts {
            let command = SlashCommand(
                name: prompt.name,
                description: prompt.description,
                hint: prompt.hint,
                local: false
            )
            let item = paletteItem(from: command, kind: .template)
            if seen.insert(item.id).inserted {
                items.append(item)
            }
        }
        for skill in skills where seen.insert("skill:\(skill.name)").inserted {
            items.append(skillItem(skill, trigger: "/skill:"))
        }
        for command in slashCommands where command.name.hasPrefix("skill:") {
            let name = String(command.name.dropFirst(6))
            if skills.contains(where: { $0.name == name }) { continue }
            items.append(paletteItem(from: command, kind: .skill, autoSend: false))
        }
        return items
    }

    private func skillPaletteItems(trigger: String) -> [PaletteItem] {
        if skills.isEmpty {
            return slashCommands
                .filter { $0.name.hasPrefix("skill:") }
                .map { command in
                    let name = String(command.name.dropFirst(6))
                    return PaletteItem(
                        kind: .skill,
                        title: "\(trigger)\(name)",
                        subtitle: command.description,
                        insert: "/skill:\(name) ",
                        autoSend: false
                    )
                }
        }
        return skills.map { skillItem($0, trigger: trigger) }
    }

    private func mentionItems(query: String) -> [PaletteItem] {
        var items: [PaletteItem] = []
        let q = query.lowercased()
        if MacClipboard.hasContent,
           q.isEmpty || "clipboard".hasPrefix(q) || "clip".hasPrefix(q) || "剪贴板".contains(q) || "剪切板".contains(q) {
            items.append(
                PaletteItem(
                    kind: .clipboard,
                    title: "@clipboard",
                    subtitle: MacClipboard.snapshot().summary,
                    insert: "@clipboard ",
                    autoSend: false
                )
            )
        }
        var files = PromptPalette.matchesFiles(workspaceFiles, query: query)
        let completions = PiCatalog.pathCompletions(query: query, workspace: OverlayPaths.workspace)
        var seen = Set(files.map(\.absolutePath))
        for file in completions where seen.insert(file.absolutePath).inserted {
            files.append(file)
        }
        items.append(contentsOf: Array(files.prefix(40)).map { file in
            let parent = (file.displayPath as NSString).deletingLastPathComponent
            return PaletteItem(
                kind: .file,
                title: file.displayPath,
                subtitle: parent.isEmpty ? "workspace" : parent,
                insert: "@\(file.displayPath) ",
                autoSend: false
            )
        })
        return items
    }

    private func appPaletteItems(query: String) -> [PaletteItem] {
        let apps = MacApps.search(query, in: installedApps.isEmpty ? nil : installedApps)
        return Array(apps.prefix(40)).map { app in
            PaletteItem(
                kind: .app,
                title: app.name,
                subtitle: app.running ? "running" : app.bundleId,
                insert: "/open \(app.name)",
                autoSend: true,
                artworkPath: app.url.path
            )
        }
    }

    private func mountPaletteItems(query: String) -> [PaletteItem] {
        _ = macEpoch
        let rows = WorkspaceRegistry.paletteRows(
            store: workspaceState,
            query: query,
            home: OverlayPaths.home,
            bubbleRoot: OverlayPaths.root,
            workspace: OverlayPaths.workspace
        )
        return rows.map { row in
            let showBadge = row.role == "enter" || row.role == "toggle"
            return PaletteItem(
                kind: .mount,
                title: row.name,
                subtitle: row.subtitle,
                insert: row.path,
                autoSend: false,
                badge: showBadge ? row.state.rawValue : nil,
                role: row.role
            )
        }
    }

    private func paletteItem(
        from command: SlashCommand,
        kind: PaletteKind = .command,
        autoSend: Bool? = nil
    ) -> PaletteItem {
        let needsArgs = command.hint != nil
        return PaletteItem(
            kind: kind,
            title: command.token,
            subtitle: command.description,
            insert: needsArgs ? command.token + " " : command.token,
            hint: command.hint,
            autoSend: autoSend ?? (command.local && !needsArgs)
        )
    }

    private func modelPaletteItems(query: String) -> [PaletteItem] {
        let models = resolvedModelCatalog()
        let items = models.map { model in
            PaletteItem(
                kind: .model,
                title: model.displayName,
                subtitle: model.identity,
                insert: "/model \(model.identity)",
                autoSend: true
            )
        }
        return PromptPalette.matches(items, query: query)
    }

    private func thinkingPaletteItems(query: String) -> [PaletteItem] {
        let items = thinkingLevels.map { level in
            PaletteItem(
                kind: .thinking,
                title: level,
                subtitle: currentThinking == level ? "current" : "Set Bubble thinking level",
                insert: "/thinking \(level)",
                autoSend: true
            )
        }
        return PromptPalette.matches(items, query: query)
    }

    private func skillItem(_ skill: PiSkill, trigger: String) -> PaletteItem {
        PaletteItem(
            kind: .skill,
            title: "\(trigger)\(skill.name)",
            subtitle: skill.description,
            insert: "/skill:\(skill.name) ",
            autoSend: false
        )
    }

    private func loginPaletteItems(query: String) -> [PaletteItem] {
        let signed = Set(PiSetup.diagnose().credentialProviders)
        let items = PiSetup.providers.map { provider in
            PaletteItem(
                kind: .command,
                title: provider.id,
                subtitle: signed.contains(provider.id) ? "\(provider.detail)  (signed in)" : provider.detail,
                insert: "/login \(provider.id)",
                autoSend: true
            )
        }
        return PromptPalette.matches(items, query: query)
    }

    private func logoutPaletteItems(query: String) -> [PaletteItem] {
        let items = PiSetup.diagnose().credentialProviders.map { id in
            PaletteItem(
                kind: .command,
                title: id,
                subtitle: "Remove saved credentials",
                insert: "/logout \(id)",
                autoSend: true
            )
        }
        return PromptPalette.matches(items, query: query)
    }

    private func resumePaletteItems(query: String) -> [PaletteItem] {
        let current = PiSessions.currentId()
        let items = sessions.map { session in
            PaletteItem(
                kind: .command,
                title: session.title,
                subtitle: session.id == current ? "\(session.timestamp)  current" : session.timestamp,
                insert: "/resume \(session.id)",
                autoSend: true
            )
        }
        return PromptPalette.matches(items, query: query)
    }

    private func treePaletteItems(query: String) -> [PaletteItem] {
        guard let tree = conversationTree else { return [] }
        let activeIDs = Set(tree.activePath.map(\.id))
        let turns = tree.entries.filter(\.isUserMessage)
        let items = turns.map { turn in
            let active = activeIDs.contains(turn.id)
            let indent = String(repeating: "  ", count: min(tree.depth(of: turn.id), 4))
            return PaletteItem(
                kind: .command,
                title: "\(indent)\(active ? "●" : "○") \(branchTitle(turn.displayText))",
                subtitle: active ? "Current path · edit and branch" : "Other path · switch here",
                insert: active ? "/tree branch:\(turn.id)" : "/tree switch:\(tree.tipID(for: turn.id))",
                autoSend: true
            )
        }
        return PromptPalette.matches(items, query: query)
    }

    func requestFocus() {
        focusTick += 1
    }

    func presentSessionMessage(_ text: String) {
        items.append(ChatItem(kind: .system, text: text))
        persist(immediate: true)
        requestFocus()
    }

    func refreshCatalog() {
        let workspace = OverlayPaths.workspace
        Self.catalogRefreshQueue.async { [weak self] in
            let skills = PiCatalog.loadSkills(workspace: workspace)
            let prompts = PiCatalog.loadPrompts(workspace: workspace)
            let files = PiCatalog.indexFiles(workspace: workspace)
            let apps = MacApps.refresh()
            let sessions = PiSessions.list()
            DispatchQueue.main.async {
                guard let self else { return }
                self.skills = skills
                self.prompts = prompts
                self.workspaceFiles = files
                self.installedApps = apps
                self.sessions = sessions
                self.macEpoch += 1
                self.syncOverlayChrome()
                OverlayLog.write("catalog skills=\(skills.count) prompts=\(prompts.count) files=\(files.count) apps=\(apps.count) sessions=\(sessions.count)")
            }
        }
    }

    func moveSlashHighlight(_ delta: Int) {
        let items = visiblePaletteItems
        guard !items.isEmpty else { return }
        slashHighlight = (slashHighlight + delta + items.count) % items.count
    }

    func completeHighlightedSlash() {
        guard let item = highlightedPaletteItem() else { return }
        if item.kind == .mount {
            handleMountPalette(item, preferEnter: true)
            return
        }
        applyPalette(item)
        requestFocus()
    }

    func leaveMountFolder() {
        guard isMountPalette else { return }
        let query = BubbleComposer.argumentQuery(command: "mounts", in: draft) ?? ""
        let parent = WorkspaceRegistry.parentQuery(query: query, home: OverlayPaths.home)
        draft = parent.isEmpty ? "/mounts " : "/mounts \(parent)"
        paletteSuppressed = false
        slashHighlight = 0
        requestFocus()
    }

    func toggleHighlightedMount() {
        guard let item = highlightedPaletteItem(), item.kind == .mount else { return }
        handleMountPalette(item, preferEnter: false)
    }

    func handleMountBadge(_ item: PaletteItem) {
        handleMountPalette(item, preferEnter: false)
    }

    func selectPalette(_ item: PaletteItem) {
        if item.kind == .mount {
            handleMountPalette(item, preferEnter: true)
            return
        }
        applyPalette(item)
        if item.autoSend {
            send()
        } else {
            requestFocus()
        }
    }

    func openMountsPalette() {
        draft = "/mounts "
        paletteSuppressed = false
        slashHighlight = 0
        requestFocus()
    }

    func dismissSlashMenu() {
        if let token = PromptPalette.activeToken(in: draft), token.trigger.query.isEmpty {
            draft = String(draft[..<token.range.lowerBound])
        } else {
            paletteSuppressed = true
        }
        slashHighlight = 0
    }

    private func highlightedPaletteItem() -> PaletteItem? {
        let items = visiblePaletteItems
        guard items.indices.contains(slashHighlight) else { return items.first }
        return items[slashHighlight]
    }

    private func applyPalette(_ item: PaletteItem) {
        if BubbleComposer.isStaged(draft) {
            draft = item.insert
        } else {
            draft = PromptPalette.replaceToken(in: draft, with: item.insert)
        }
        slashHighlight = 0
        paletteSuppressed = !BubbleComposer.isStaged(draft)
    }

    func connect() async {
        status = "connecting"
        let report = PiSetup.diagnose()
        if !report.piInstalled || !report.acpAvailable {
            isConnected = false
            status = "setup"
            presentSetup(report)
            return
        }
        do {
            if runtimeRole == .main {
                _ = try await client.connectAndResume()
            } else {
                _ = try await client.reconnectSideSession()
            }
            isConnected = true
            status = "ready"
            onSessionIdentityChanged?()
            removeSetupCards(persistNow: true)
            syncSessionConfig()
            refreshCatalog()
            await restoreConversationTree(replacingTranscript: !isBusy && !isStartingSession)
            announceInterruptedWorkspaceIfNeeded()
            let readyReport = PiSetup.diagnose()
            if StartupTranscriptPolicy.shouldPresentAfterConnection(hasCredentials: readyReport.hasCredentials) {
                presentSetup(readyReport, error: "Pi is running, but no provider is signed in.")
            }
        } catch {
            isConnected = false
            status = friendly(error)
            OverlayLog.write("connect failed: \(status)")
            presentSetup(PiSetup.diagnose(), error: friendly(error))
            client.stop()
        }
    }

    func send() {
        if isMountPalette, slashMenuVisible {
            if let item = highlightedPaletteItem() {
                handleMountPalette(item, preferEnter: true)
            }
            return
        }
        if slashMenuVisible, let item = highlightedPaletteItem() {
            applyPalette(item)
            if item.hint != nil {
                requestFocus()
                return
            }
        }
        send(text: draft, forceClipboard: false)
    }

    var hasComposerPayload: Bool {
        !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !draftClips.isEmpty
            || !draftImages.isEmpty
    }

    func attachDraftClip(_ text: String, kind: DraftClip.Kind = .paste) {
        let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { return }
        if draftClips.contains(where: { $0.text == body && $0.kind == kind }) { return }
        if draftClips.count >= 8 { return }
        draftClips.append(DraftClip(text: body, kind: kind))
        requestFocus()
    }

    func attachDraftImage(_ png: Data) {
        guard !png.isEmpty, png.count <= OverlayComposer.maxImageBytes else { return }
        if draftImages.count >= OverlayComposer.maxImages { return }
        draftImages.append(DraftImage(png: png))
        requestFocus()
    }

    func removeDraftClip(_ id: UUID) {
        draftClips.removeAll { $0.id == id }
        requestFocus()
    }

    func removeDraftImage(_ id: UUID) {
        draftImages.removeAll { $0.id == id }
        requestFocus()
    }

    func consumeComposer() {
        draft = ""
        draftClips = []
        draftImages = []
    }

    func beginBranch(from item: ChatItem) {
        guard !isBusy, !childBusy, !isStartingSession, !isSwitchingBranch,
              item.kind == .user || item.kind == .assistant,
              (item.imageNames ?? []).isEmpty,
              item.sourceBranchable != false,
              let targetEntryID = item.sourceEntryId,
              let originalLeafID = conversationTree?.leafID,
              let sourceEntry = conversationTree?.entries.first(where: { $0.id == targetEntryID }) else { return }
        let suspended = branchDraft.map {
            ($0.suspendedDraft, $0.suspendedClips, $0.suspendedImages)
        } ?? (draft, draftClips, draftImages)
        branchDraft = ConversationBranchDraft(
            targetEntryID: targetEntryID,
            originalLeafID: originalLeafID,
            sourceItemID: item.id,
            title: branchTitle(sourceEntry.displayText),
            suspendedDraft: suspended.0,
            suspendedClips: suspended.1,
            suspendedImages: suspended.2
        )
        draft = item.kind == .user ? sourceEntry.displayText : ""
        draftClips = []
        draftImages = []
        paletteSuppressed = true
        requestFocus()
    }

    private func beginBranch(entryID: String) {
        if let item = items.first(where: { $0.sourceEntryId == entryID && $0.kind == .user }) {
            beginBranch(from: item)
            return
        }
        guard let entry = conversationTree?.entries.first(where: { $0.id == entryID && $0.isUserMessage }) else { return }
        beginBranch(from: ChatItem(
            kind: .user,
            text: entry.displayText,
            sourceEntryId: entry.id,
            sourceBranchable: !entry.hasStructuredContent
        ))
    }

    func cancelBranchDraft() {
        guard let branchDraft else { return }
        draft = branchDraft.suspendedDraft
        draftClips = branchDraft.suspendedClips
        draftImages = branchDraft.suspendedImages
        self.branchDraft = nil
        requestFocus()
    }

    func variants(for item: ChatItem) -> [ConversationVariant] {
        guard let entryID = item.sourceEntryId else { return [] }
        return conversationTree?.variants(around: entryID) ?? []
    }

    func switchConversationBranch(to variant: ConversationVariant) {
        switchConversationBranch(to: variant.tipID)
    }

    private func switchConversationBranch(to targetID: String) {
        guard !isBusy, !childBusy, !isStartingSession, !isSwitchingBranch,
              targetID != conversationTree?.leafID else { return }
        cancelBranchDraft()
        let originalLeafID = conversationTree?.leafID
        isSwitchingBranch = true
        status = "switching branch"
        Task { @MainActor in
            do {
                let snapshot = try await client.selectConversationLeaf(targetID)
                applyConversationTree(snapshot, replacingTranscript: true)
                status = "ready"
            } catch {
                if let snapshot = try? await client.conversationTree() {
                    applyConversationTree(snapshot, replacingTranscript: true)
                } else if let originalLeafID,
                          let restored = try? await client.selectConversationLeaf(originalLeafID) {
                    applyConversationTree(restored, replacingTranscript: true)
                }
                status = friendly(error)
                items.append(ChatItem(kind: .system, text: friendly(error)))
                persist(immediate: true)
            }
            isSwitchingBranch = false
            requestFocus()
        }
    }

    func attachClipboard() {
        if !draft.localizedCaseInsensitiveContains("@clipboard") {
            if draft.isEmpty || draft.hasSuffix(" ") {
                draft += "@clipboard "
            } else {
                draft += " @clipboard "
            }
        }
        macEpoch += 1
        requestFocus()
    }

    private func send(text raw: String, forceClipboard: Bool) {
        guard ConversationBranchInteraction.canSend(isSwitchingBranch: isSwitchingBranch) else {
            status = "wait for the branch switch to finish"
            return
        }
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let composerClips = draftClips
        let composerImages = draftImages
        let imageData = composerImages.map(\.png)
        let branch = branchDraft
        guard !text.isEmpty || !composerClips.isEmpty || !imageData.isEmpty else { return }
        if branch == nil, SlashCommand.token(in: text) == "side", handleLocalSlash(text) {
            consumeComposer()
            return
        }
        guard branch == nil || !isBusy else {
            status = "finish the current turn before branching"
            return
        }
        if branch == nil, !isBusy, handleLocalSlash(text) {
            consumeComposer()
            return
        }
        if branch == nil, !isBusy, let app = MacApps.launchIntent(from: text) {
            consumeComposer()
            openApp(app)
            return
        }
        let payload = OverlayComposer.sendPayload(draft: text, clips: composerClips, imageCount: imageData.count)
        let files = PiCatalog.attachments(in: payload.prompt, workspace: OverlayPaths.workspace)
        let mac = MacClipboard.expand(payload.prompt, force: forceClipboard)
        var attachments = files
        for item in mac.attachments where !attachments.contains(where: { $0.uri == item.uri }) {
            attachments.append(item)
        }
        var images = imageData.map { PromptImage(mimeType: "image/png", data: $0) }
        for image in mac.images where !images.contains(where: { $0.data == image.data }) {
            images.append(image)
        }
        consumeComposer()
        branchDraft = nil
        var stored: [String] = []
        var seen = Set<Data>()
        for png in imageData + images.map(\.data) {
            guard seen.insert(png).inserted else { continue }
            if let name = BubbleImages.save(png) {
                stored.append(name)
            }
        }
        let display = payload.display.isEmpty && stored.isEmpty && !images.isEmpty
            ? "Image"
            : payload.display
        let itemId = UUID()
        let queued = MessageDeliveryPolicy.shouldQueue(
            isBusy: isBusy,
            isBranching: branch != nil
        )
        let prompt = PendingPrompt(
            itemId: itemId,
            display: display,
            imageNames: stored,
            text: mac.text,
            attachments: attachments,
            images: images,
            branch: branch,
            draftText: text,
            draftClips: composerClips,
            draftImages: composerImages
        )
        if queued {
            pendingPrompts.append(prompt)
            status = "waiting"
            requestFocus()
            return
        }
        if branch == nil {
            appendUserItem(for: prompt)
        }
        startPrompt(prompt)
    }

    private func startPrompt(_ prompt: PendingPrompt) {
        if prompt.branch == nil, !items.contains(where: { $0.id == prompt.itemId }) {
            appendUserItem(for: prompt)
        }
        setDeliveryState(nil, for: prompt.itemId)
        isBusy = true
        streamingAssistantId = nil
        streamingThoughtId = nil
        turnStartedAt = Date()
        status = "thinking"
        runNonce += 1
        let nonce = runNonce
        activeBranchPrompt = prompt.branch == nil ? nil : prompt
        activeBranchNavigationSucceeded = false

        Task { @MainActor in
            do {
                if !isConnected {
                    client.stop()
                    await connect()
                    guard isConnected else {
                        if nonce == self.runNonce {
                            isBusy = false
                            startNextWaitingPrompt()
                        }
                        return
                    }
                }
                if let branch = prompt.branch {
                    let snapshot = try await client.navigateConversation(to: branch.targetEntryID)
                    guard nonce == self.runNonce else {
                        _ = try? await client.selectConversationLeaf(branch.originalLeafID)
                        return
                    }
                    activeBranchNavigationSucceeded = true
                    applyConversationTree(snapshot, replacingTranscript: true, persistSelection: false)
                    appendUserItem(for: prompt)
                }
                let promptSessionID = client.sessionId
                let wrapped = wrappedText(for: prompt)
                let stop = try await client.prompt(
                    wrapped,
                    attachments: prompt.attachments,
                    images: prompt.images
                )
                guard nonce == self.runNonce else { return }
                status = stop == "end_turn" || stop == "cancelled" ? "ready" : stop
                await refreshConversationTree(
                    expectedRunNonce: nonce,
                    expectedSessionID: promptSessionID
                )
            } catch {
                guard nonce == self.runNonce else { return }
                if let branch = prompt.branch {
                    let snapshot = activeBranchNavigationSucceeded ? try? await client.conversationTree() : nil
                    let persisted = snapshot.map {
                        ConversationBranchRecovery.promptWasPersisted(
                            in: $0,
                            after: branch.targetEntryID,
                            navigationSucceeded: activeBranchNavigationSucceeded
                        )
                    } ?? false
                    if persisted, let snapshot {
                        applyConversationTree(snapshot, replacingTranscript: true)
                    }
                    if !persisted {
                        let restored = try? await client.selectConversationLeaf(branch.originalLeafID)
                        let fallback = conversationTree?.selecting(leafID: branch.originalLeafID)
                        if let restored = restored ?? fallback {
                            applyConversationTree(restored, replacingTranscript: true)
                        }
                        branchDraft = branch
                        draft = prompt.draftText
                        draftClips = prompt.draftClips
                        draftImages = prompt.draftImages
                    }
                }
                items.append(ChatItem(kind: .system, text: friendly(error)))
                persist(immediate: true)
                status = friendly(error)
            }
            guard nonce == self.runNonce else { return }
            activeBranchPrompt = nil
            activeBranchNavigationSucceeded = false
            if let start = turnStartedAt {
                lastTurnDuration = Date().timeIntervalSince(start)
            }
            flushStreamChunks()
            isBusy = false
            hushMainAssistant = false
            streamingAssistantId = nil
            streamingThoughtId = nil
            turnStartedAt = nil
            clearSteeringMessages()
            persist(immediate: true)
            requestFocus()
            flushPendingInjection()
            startNextWaitingPrompt()
        }
    }

    func steerQueuedMessage(_ id: UUID) {
        guard MessageDeliveryPolicy.canSteer(.waiting, isBusy: isBusy),
              let pendingIndex = pendingPrompts.firstIndex(where: { $0.itemId == id }) else {
            return
        }
        let prompt = pendingPrompts.remove(at: pendingIndex)
        steeringMessageIds.insert(id)
        appendUserItem(for: prompt, deliveryState: .steering)

        Task { @MainActor in
            do {
                let wrapped = MessageDeliveryPolicy.steeringText(
                    wrappedText(for: prompt),
                    resourceURIs: prompt.attachments.map(\.uri)
                )
                try await client.steer(wrapped, images: prompt.images)
                status = "steering"
                OverlayLog.write("steered queued message \(id.uuidString)")
            } catch {
                let insertion = min(pendingIndex, pendingPrompts.count)
                pendingPrompts.insert(prompt, at: insertion)
                steeringMessageIds.remove(id)
                items.removeAll { $0.id == id }
                items.append(ChatItem(kind: .system, text: friendly(error)))
                status = "waiting"
                persist(immediate: true)
                startNextWaitingPrompt()
            }
            requestFocus()
        }
    }

    private func startNextWaitingPrompt() {
        guard !isBusy, !pendingPrompts.isEmpty else { return }
        let next = pendingPrompts.removeFirst()
        startPrompt(next)
    }

    private func appendUserItem(
        for prompt: PendingPrompt,
        deliveryState: MessageDeliveryState? = nil
    ) {
        items.append(
            ChatItem(
                id: prompt.itemId,
                kind: .user,
                text: prompt.display,
                imageNames: prompt.imageNames.isEmpty ? nil : prompt.imageNames,
                deliveryState: deliveryState
            )
        )
        persist(immediate: true)
    }

    private func wrappedText(for prompt: PendingPrompt) -> String {
        WorkspaceRegistry.wrapUserPrompt(
            prompt.text,
            store: workspaceState,
            home: OverlayPaths.home.path,
            skillsByMount: mountSkillNames
        )
    }

    private func setDeliveryState(_ state: MessageDeliveryState?, for id: UUID) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        items[index].deliveryState = state
    }

    private func clearSteeringMessages() {
        for id in steeringMessageIds {
            setDeliveryState(nil, for: id)
        }
        steeringMessageIds.removeAll()
    }

    func cancel() {
        let branchPrompt = activeBranchPrompt
        let branchNavigationSucceeded = activeBranchNavigationSucceeded
        runNonce += 1
        client.cancel()
        for index in items.indices {
            if items[index].kind == .tool {
                let status = items[index].toolStatus ?? ""
                if status != "completed" && status != "failed" && status != "cancelled" {
                    items[index].toolStatus = "cancelled"
                }
            }
        }
        flushStreamChunks()
        isBusy = false
        injecting = false
        hushMainAssistant = false
        streamingAssistantId = nil
        streamingThoughtId = nil
        status = "cancelled"
        clearSteeringMessages()
        OverlayLog.write("cancelled in-flight turn")
        requestFocus()
        guard let branchPrompt, let branch = branchPrompt.branch else {
            activeBranchPrompt = nil
            activeBranchNavigationSucceeded = false
            persist(immediate: true)
            startNextWaitingPrompt()
            return
        }
        Task { @MainActor in
            let snapshot = branchNavigationSucceeded ? try? await client.conversationTree() : nil
            let persisted = snapshot.map {
                ConversationBranchRecovery.promptWasPersisted(
                    in: $0,
                    after: branch.targetEntryID,
                    navigationSucceeded: branchNavigationSucceeded
                )
            } ?? false
            if persisted, let snapshot {
                applyConversationTree(snapshot, replacingTranscript: true)
            } else {
                let restored = try? await client.selectConversationLeaf(branch.originalLeafID)
                let fallback = conversationTree?.selecting(leafID: branch.originalLeafID)
                if let restored = restored ?? fallback {
                    applyConversationTree(restored, replacingTranscript: true)
                }
                branchDraft = branch
                draft = branchPrompt.draftText
                draftClips = branchPrompt.draftClips
                draftImages = branchPrompt.draftImages
            }
            activeBranchPrompt = nil
            activeBranchNavigationSucceeded = false
            persist(immediate: true)
            requestFocus()
            startNextWaitingPrompt()
        }
    }

    private func applyUpdateData(_ data: Data) {
        guard let params = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        applyUpdate(params)
    }

    private func routeUpdate(_ sessionId: String, _ data: Data) {
        let mainId = client.sessionId
        if WorkspaceRunLifecyclePolicy.acceptsStreamUpdate(
            routedSessionId: sessionId,
            activeChildSessionId: childSessionId,
            childBusy: childBusy
        ) {
            applyChildUpdateData(data, sessionId: sessionId)
            return
        }
        if !sessionId.isEmpty, sessionId != mainId {
            return
        }
        applyUpdateData(data)
    }

    private func applyUpdate(_ params: [String: Any]) {
        let update = params.dictionary("update") ?? params
        let kind = update.string("sessionUpdate") ?? ""
        switch kind {
        case "agent_message_chunk":
            if hushMainAssistant { return }
            if JSONValue.bool(update["bubbleCustomMessageStart"]) == true {
                flushStreamChunks()
                streamingAssistantId = nil
                forceNewAssistantRow = true
            }
            if let content = AssistantMessageContent.parse(update["content"]) {
                if injecting { injectSpoke = true }
                switch content {
                case .text(let text): appendAssistant(text)
                case .image(let image): appendAssistantImage(image)
                }
            }
            if JSONValue.bool(update["bubbleCustomMessageEnd"]) == true {
                flushStreamChunks()
                streamingAssistantId = nil
                forceNewAssistantRow = true
            }
        case "agent_thought_chunk":
            if hushMainAssistant || injecting { return }
            if let text = extractText(update["content"]), !text.isEmpty {
                appendThought(text)
            }
        case "user_message_chunk":
            break
        case "available_commands_update":
            mergeAdvertisedCommands(update.array("availableCommands") ?? [])
        case "config_option_update":
            syncSessionConfig()
        case "tool_call", "tool_call_update":
            if injecting {
                OverlayLog.write("workspace relay used a tool, aborting tools")
                client.cancel()
                return
            }
            if isWorkspaceRunTool(update) {
                return
            }
            upsertTool(update, isUpdate: kind == "tool_call_update")
        default:
            break
        }
    }

    private func mergeAdvertisedCommands(_ raw: [Any]) {
        let incoming = raw.compactMap(SlashCommand.parse)
        guard !incoming.isEmpty else { return }
        var map = Dictionary(uniqueKeysWithValues: SlashCommand.builtIn.map { ($0.name, $0) })
        for command in incoming {
            if map[command.name]?.local == true { continue }
            map[command.name] = command
        }
        slashCommands = map.values.sorted { $0.name < $1.name }
        OverlayLog.write("slash commands \(slashCommands.count)")
    }

    @discardableResult
    private func handleLocalSlash(_ text: String) -> Bool {
        guard let name = SlashCommand.token(in: text) else { return false }
        switch name {
        case "help":
            draft = ""
            items.append(ChatItem(kind: .system, text: SlashCommand.helpText(from: slashCommands, skills: skills)))
            persist(immediate: true)
            requestFocus()
            return true
        case "skill", "skill:":
            draft = ""
            items.append(ChatItem(kind: .system, text: skillHelpText()))
            persist(immediate: true)
            requestFocus()
            return true
        case "model":
            draft = ""
            let args = SlashCommand.arguments(in: text)
            if args.isEmpty {
                items.append(ChatItem(kind: .system, text: modelHelpText()))
                persist(immediate: true)
                requestFocus()
                return true
            }
            applyModel(args, announce: true)
            return true
        case "thinking":
            draft = ""
            let args = SlashCommand.arguments(in: text)
            if args.isEmpty {
                items.append(ChatItem(kind: .system, text: thinkingHelpText()))
                persist(immediate: true)
                requestFocus()
                return true
            }
            applyThinking(args, announce: true)
            return true
        case "agents":
            draft = ""
            BubbleConfig.openAgentsFile()
            items.append(ChatItem(kind: .system, text: "Opened ~/.bubble/AGENTS.md"))
            persist(immediate: true)
            requestFocus()
            return true
        case "open":
            draft = ""
            let args = SlashCommand.arguments(in: text)
            if args.isEmpty {
                items.append(ChatItem(kind: .system, text: "Type /open then pick an app, for example /open Safari."))
                persist(immediate: true)
                requestFocus()
                return true
            }
            if let app = MacApps.resolve(args) {
                openApp(app)
            } else {
                items.append(ChatItem(kind: .system, text: "No installed app matching “\(args)”."))
                persist(immediate: true)
                requestFocus()
            }
            return true
        case "mounts":
            draft = ""
            let args = SlashCommand.arguments(in: text)
            if args.isEmpty {
                openMountsPalette()
                return true
            }
            do {
                let path = WorkspaceRegistry.expandPath(args, home: OverlayPaths.home)
                let action = try toggleMount(path)
                items.append(ChatItem(kind: .system, text: mountMessage(action: action, path: path)))
            } catch {
                items.append(ChatItem(kind: .system, text: error.localizedDescription))
            }
            persist(immediate: true)
            requestFocus()
            return true
        case "clipboard":
            draft = ""
            let args = SlashCommand.arguments(in: text)
            let prompt = args.isEmpty ? "Here is my clipboard." : args
            send(text: prompt + " @clipboard", forceClipboard: true)
            return true
        case "clear", "new":
            draft = ""
            startFreshConversation()
            return true
        case "side":
            draft = ""
            onCreateSideSession?()
            return true
        case "copy":
            draft = ""
            copyLastAssistant()
            requestFocus()
            return true
        case "quit", "exit":
            draft = ""
            onHideOverlay?()
            return true
        case "setup", "install":
            draft = ""
            handleSetup()
            return true
        case "login":
            draft = ""
            handleLogin(SlashCommand.arguments(in: text))
            return true
        case "logout":
            draft = ""
            handleLogout(SlashCommand.arguments(in: text))
            return true
        case "resume":
            draft = ""
            handleResume(SlashCommand.arguments(in: text))
            return true
        case "tree":
            handleTree(SlashCommand.arguments(in: text))
            return true
        case "reload":
            draft = ""
            handleReload()
            return true
        case "settings", "hotkeys", "llama", "scoped-models", "fork", "clone":
            draft = ""
            items.append(ChatItem(kind: .system, text: tuiOnlyHelp(name)))
            persist(immediate: true)
            requestFocus()
            return true
        default:
            return false
        }
    }

    private func presentSetup(_ report: PiSetup.Report, error: String? = nil) {
        replaceSetupCard(PiSetup.setupCard(report, error: error), persistNow: true)
    }

    private func handleSetup() {
        if isInstalling {
            appendSetupLog("Install is already running.")
            requestFocus()
            return
        }
        isInstalling = true
        status = "setup"
        replaceSetupCard("Set up Bubble\nChecking Node, Pi, and the ACP adapter…", persistNow: true)
        OverlayLog.write("setup start")
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            do {
                let outcome = try PiBootstrap.install { line in
                    DispatchQueue.main.async {
                        self?.appendSetupLog(line)
                    }
                }
                DispatchQueue.main.async {
                    self?.finishSetup(outcome)
                }
            } catch {
                DispatchQueue.main.async {
                    self?.failSetup(error)
                }
            }
        }
    }

    private func finishSetup(_ outcome: PiBootstrap.Outcome) {
        switch outcome {
        case .alreadyReady:
            appendSetupLog("Already installed. Reconnecting…")
            isInstalling = false
            handleReload()
        case .needNode(let detail):
            presentSetup(PiSetup.diagnose(), error: detail)
            isInstalling = false
            status = "setup"
            requestFocus()
        case .installed:
            appendSetupLog("Installed into ~/.bubble/runtime. Reconnecting…")
            isInstalling = false
            handleReload()
        }
    }

    private func failSetup(_ error: Error) {
        OverlayLog.write("setup failed: \(error.localizedDescription)")
        presentSetup(PiSetup.diagnose(), error: friendly(error))
        isInstalling = false
        status = "setup"
        requestFocus()
    }

    private func setupCardIndex() -> Int? {
        items.lastIndex(where: {
            StartupTranscriptPolicy.isSetupCard($0.text, isSystem: $0.kind == .system)
        })
    }

    private func removeSetupCards(persistNow: Bool) {
        let previousCount = items.count
        items.removeAll {
            StartupTranscriptPolicy.isSetupCard($0.text, isSystem: $0.kind == .system)
        }
        guard persistNow, items.count != previousCount else { return }
        persist(immediate: true)
    }

    private func replaceSetupCard(_ card: String, persistNow: Bool) {
        if items.last?.text == card { return }
        if let index = setupCardIndex() {
            items[index].text = card
        } else {
            items.append(ChatItem(kind: .system, text: card))
        }
        if persistNow {
            persist(immediate: true)
        }
    }

    private func appendSetupLog(_ line: String) {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        OverlayLog.write("setup: \(trimmed)")
        var lines: [String]
        if let index = setupCardIndex() {
            lines = items[index].text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        } else {
            lines = ["Set up Bubble"]
        }
        if lines.last == trimmed { return }
        lines.append(trimmed)
        if lines.count > 30 {
            lines = Array(lines.prefix(2)) + ["…"] + Array(lines.suffix(27))
        }
        replaceSetupCard(lines.joined(separator: "\n"), persistNow: false)
    }

    private func handleLogin(_ args: String) {
        let parts = args.split(whereSeparator: \.isWhitespace).map(String.init)
        if parts.isEmpty {
            items.append(ChatItem(kind: .system, text: PiSetup.loginHelp()))
            persist(immediate: true)
            requestFocus()
            return
        }
        let provider = parts[0].lowercased()
        if parts.count >= 2 {
            let key = parts.dropFirst().joined(separator: " ")
            do {
                try PiSetup.saveAPIKey(provider: provider, key: key)
                items.append(ChatItem(
                    kind: .system,
                    text: "Saved \(provider) key \(PiSetup.maskedKey(key)). Reconnecting…"
                ))
                persist(immediate: true)
                handleReload()
            } catch {
                items.append(ChatItem(kind: .system, text: error.localizedDescription))
                persist(immediate: true)
                requestFocus()
            }
            return
        }
        items.append(ChatItem(
            kind: .system,
            text: "Opening Terminal for Pi login (\(provider)).\nIn Pi, type /login and finish the flow. Then come back and type /reload.\n\nAPI key instead: /login \(provider) sk-..."
        ))
        persist(immediate: true)
        if let error = PiSetup.openPiTerminal() {
            items.append(ChatItem(kind: .system, text: "Could not open Terminal: \(error)"))
            persist(immediate: true)
        }
        requestFocus()
    }

    private func handleLogout(_ args: String) {
        let provider = args.trimmingCharacters(in: .whitespacesAndNewlines)
        if provider.isEmpty {
            let signed = PiSetup.diagnose().credentialProviders
            if signed.isEmpty {
                items.append(ChatItem(kind: .system, text: "No saved providers. Type /login to add one."))
            } else {
                items.append(ChatItem(
                    kind: .system,
                    text: "Signed in: \(signed.joined(separator: ", "))\nType /logout \(signed[0]) to remove one."
                ))
            }
            persist(immediate: true)
            requestFocus()
            return
        }
        do {
            if try PiSetup.removeProvider(provider) {
                items.append(ChatItem(kind: .system, text: "Removed \(provider)."))
            } else {
                items.append(ChatItem(kind: .system, text: "No saved credentials for \(provider)."))
            }
        } catch {
            items.append(ChatItem(kind: .system, text: error.localizedDescription))
        }
        persist(immediate: true)
        requestFocus()
    }

    private func handleResume(_ args: String) {
        let id = args.trimmingCharacters(in: .whitespacesAndNewlines)
        if id.isEmpty {
            sessions = PiSessions.list()
            items.append(ChatItem(kind: .system, text: PiSessions.resumeHelp(sessions: sessions, current: PiSessions.currentId())))
            persist(immediate: true)
            requestFocus()
            return
        }
        if !ResumeDestinationPolicy.requiresChoice(
            sessionID: id,
            currentSessionID: currentSessionID
        ) {
            items.append(ChatItem(kind: .system, text: "Session \(id) is already open here."))
            persist(immediate: true)
            requestFocus()
            return
        }
        resumeDestination.request(sessionID: id)
        resumeActionGeneration &+= 1
        requestFocus()
    }

    func resolveResumeDestination(_ choice: ResumeDestinationChoice) {
        guard let outcome = resumeDestination.choose(choice) else { return }
        guard outcome == .actionQueued else {
            requestFocus()
            return
        }
        resumeActionGeneration &+= 1
        let generation = resumeActionGeneration
        requestFocus()
        OverlayPulse.shared.onNextFrame { [weak self] in
            guard let self, self.resumeActionGeneration == generation else { return }
            OverlayPulse.shared.onNextFrame { [weak self] in
                guard let self, self.resumeActionGeneration == generation,
                      let resolution = self.resumeDestination.takePendingAction() else { return }
                self.performResumeDestination(resolution)
            }
        }
    }

    private func performResumeDestination(_ resolution: ResumeDestinationResolution) {
        switch resolution {
        case .side(let sessionID):
            if let ordinal = onResumeInSideSession?(sessionID) {
                presentSessionMessage("Opening session \(sessionID) in Side Session \(ordinal).")
            }
        case .replaceCurrent(let sessionID):
            resumeReplacingCurrent(sessionID)
        case .cancelled:
            requestFocus()
        }
    }

    func resumeReplacingCurrent(_ id: String) {
        finishPendingTranscriptRestore()
        transcriptLoadGeneration &+= 1
        let loadGeneration = transcriptLoadGeneration
        writeTranscript()
        transcriptRestorePending = true
        let previousItems = items
        let previousRichRows = richTranscriptRows
        let previousTree = conversationTree
        let previousHistoryTurnCapacity = transcriptHistoryTurnCapacity
        isStartingSession = true
        items = []
        transcriptHistoryTurnCapacity = TranscriptHistoryWindow.configuredInitialCapacity
        richTranscriptRows = [:]
        closeSideStage(animated: false)
        status = "resuming"
        Task { @MainActor in
            do {
                if !isConnected {
                    await connect()
                }
                _ = try await client.switchToSession(id, persistAsMain: runtimeRole.persistsAsMain)
                onSessionIdentityChanged?()
                let restored = await Self.loadTranscriptOffMain(sessionID: id)
                guard transcriptLoadGeneration == loadGeneration else { return }
                transcriptRestorePending = false
                mergeRestoredTranscript(restored, removingSetupCards: false)
                isConnected = true
                status = "ready"
                syncSessionConfig()
                refreshCatalog()
                await restoreConversationTree(replacingTranscript: true)
                if items.isEmpty {
                    items.append(ChatItem(kind: .system, text: "Resumed session \(id)."))
                    persist(immediate: true)
                }
            } catch {
                guard transcriptLoadGeneration == loadGeneration else { return }
                transcriptRestorePending = false
                items = previousItems
                richTranscriptRows = previousRichRows
                conversationTree = previousTree
                transcriptHistoryTurnCapacity = previousHistoryTurnCapacity
                status = friendly(error)
                items.append(ChatItem(kind: .system, text: friendly(error)))
                persist(immediate: true)
            }
            guard transcriptLoadGeneration == loadGeneration else { return }
            isStartingSession = false
            requestFocus()
        }
    }

    private func handleTree(_ args: String) {
        let trimmed = args.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            draft = "/tree "
            let treeSessionID = client.sessionId
            Task { @MainActor in
                await refreshConversationTree(expectedSessionID: treeSessionID)
                requestFocus()
            }
            requestFocus()
            return
        }
        if trimmed.hasPrefix("branch:") {
            beginBranch(entryID: String(trimmed.dropFirst(7)))
            requestFocus()
            return
        }
        if trimmed.hasPrefix("switch:") {
            switchConversationBranch(to: String(trimmed.dropFirst(7)))
            draft = ""
            requestFocus()
            return
        }
        draft = ""
        items.append(ChatItem(kind: .system, text: "That branch point is no longer in this session. Type /tree to refresh it."))
        persist(immediate: true)
        requestFocus()
    }

    private func handleReload() {
        isConnected = false
        status = "reloading"
        client.stopForReload()
        items.append(ChatItem(kind: .system, text: "Reconnecting to Pi…"))
        persist(immediate: true)
        Task { @MainActor in
            await connect()
            refreshCatalog()
            if isConnected {
                items.append(ChatItem(kind: .system, text: "Bubble is ready."))
                persist(immediate: true)
            }
            requestFocus()
        }
    }

    private func tuiOnlyHelp(_ name: String) -> String {
        switch name {
        case "settings":
            return "/settings is Pi’s terminal UI. In Bubble use the menu bar, /model, or /thinking."
        case "fork", "clone":
            return "/\(name) needs Pi’s session picker. Run `pi` in Terminal, then /\(name)."
        default:
            return "/\(name) is a Pi terminal command. Open Terminal with /login, or run `pi`."
        }
    }

    private func startFreshConversation() {
        finishPendingTranscriptRestore()
        transcriptLoadGeneration &+= 1
        writeTranscript()
        isStartingSession = true
        items = []
        transcriptHistoryTurnCapacity = TranscriptHistoryWindow.configuredInitialCapacity
        richTranscriptRows = [:]
        streamingAssistantId = nil
        streamingThoughtId = nil
        lastTurnDuration = 0
        closeSideStage(animated: false)
        clearActiveWorkspaceRun()
        status = "new session"
        Task { @MainActor in
            do {
                if !isConnected {
                    await connect()
                }
                _ = try await client.startFreshSession(persistAsMain: runtimeRole.persistsAsMain)
                onSessionIdentityChanged?()
                try resetWorkspaceSessionsForFreshMainSession()
                isConnected = true
                status = "ready"
                syncSessionConfig()
                conversationTree = nil
                branchDraft = nil
                items.append(ChatItem(kind: .system, text: "Bubble is ready."))
                persist(immediate: true)
            } catch {
                status = friendly(error)
                items.append(ChatItem(kind: .system, text: friendly(error)))
                persist(immediate: true)
            }
            isStartingSession = false
            requestFocus()
        }
    }

    func applyModel(_ identity: String, announce: Bool = false) {
        let parsed = AgentModel.parse(identity)
        Task { @MainActor in
            do {
                if !isConnected {
                    await connect()
                }
                try await client.setConfigOption(id: "model", value: parsed.identity)
                BubbleConfig.update { $0.setModel(identity: parsed.identity) }
                currentModelId = parsed.identity
                notifyConfigChanged()
                if announce {
                    items.append(ChatItem(kind: .system, text: "Bubble model set to \(parsed.identity). Pi TUI is unchanged."))
                    persist(immediate: true)
                }
            } catch {
                items.append(ChatItem(kind: .system, text: friendly(error)))
                persist(immediate: true)
            }
            requestFocus()
        }
    }

    func applyThinking(_ level: String, announce: Bool = false) {
        let value = level.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        Task { @MainActor in
            do {
                if !isConnected {
                    await connect()
                }
                try await client.setConfigOption(id: "thought_level", value: value)
                BubbleConfig.update { $0.thinking = value }
                currentThinking = value
                notifyConfigChanged()
                if announce {
                    items.append(ChatItem(kind: .system, text: "Bubble thinking set to \(value)."))
                    persist(immediate: true)
                }
            } catch {
                items.append(ChatItem(kind: .system, text: friendly(error)))
                persist(immediate: true)
            }
            requestFocus()
        }
    }

    func openAgentsFile() {
        BubbleConfig.openAgentsFile()
    }

    func presentLogin() {
        paletteSuppressed = true
        draft = ""
        handleLogin("")
    }

    private func openApp(_ app: MacApp) {
        if let error = MacApps.launch(app) {
            items.append(ChatItem(kind: .system, text: "Could not open \(app.name): \(error)"))
        } else {
            items.append(ChatItem(kind: .system, text: "Opening \(app.name)…"))
            onHideOverlay?()
        }
        persist(immediate: true)
        requestFocus()
    }

    private func syncSessionConfig() {
        if let model = client.currentModelId, !model.isEmpty {
            currentModelId = model
        }
        if !client.thinkingLevels.isEmpty {
            thinkingLevels = client.thinkingLevels
        }
        if let thinking = client.currentThinking, !thinking.isEmpty {
            currentThinking = thinking
        }
        notifyConfigChanged()
    }

    private func notifyConfigChanged() {
        NotificationCenter.default.post(name: .bubbleSessionConfigDidChange, object: nil)
    }

    func resolvedModelCatalog() -> [AgentModel] {
        ModelCatalogPolicy.merge(
            sessionModels: client.availableModels,
            installedModels: BubbleConfig.catalogModels(),
            currentIdentity: currentModelId
        )
    }

    private func modelHelpText() -> String {
        let models = resolvedModelCatalog()
        if models.isEmpty {
            return "No models found. Run `pi` in Terminal to log in, then reopen Bubble."
        }
        let current = currentModelId ?? "unset"
        let lines = models.map { model in
            let mark = model.identity == current ? "  (current)" : ""
            return "/model \(model.identity)\(mark)"
        }
        return "Bubble model: \(current)\nThis does not change Pi's TUI default.\n\n" + lines.joined(separator: "\n")
    }

    private func thinkingHelpText() -> String {
        let current = currentThinking ?? "unset"
        let lines = thinkingLevels.map { level in
            let mark = level == current ? "  (current)" : ""
            return "/thinking \(level)\(mark)"
        }
        return "Bubble thinking: \(current)\n\n" + lines.joined(separator: "\n")
    }

    private func skillHelpText() -> String {
        if skills.isEmpty {
            return "No Pi skills found. Add SKILL.md under ~/.pi/agent/skills or ~/.agents/skills."
        }
        let lines = skills.map { "/skill:\($0.name) — \($0.description)" }
        return "Skills\nType $ or /skill:name to pick one.\n\n" + lines.joined(separator: "\n")
    }

    private func copyLastAssistant() {
        let text = items.reversed().first(where: { $0.kind == .assistant })?.text
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let text, !text.isEmpty else {
            items.append(ChatItem(kind: .system, text: "No assistant message to copy."))
            persist(immediate: true)
            return
        }
        let board = NSPasteboard.general
        board.clearContents()
        board.setString(text, forType: .string)
        items.append(ChatItem(kind: .system, text: "Copied last reply."))
        persist(immediate: true)
    }

    private func appendAssistant(_ raw: String) {
        pendingAssistantChunk += raw
        queueStreamFlush()
    }

    private func appendAssistantImage(_ image: AssistantMessageImage) {
        flushStreamChunks()
        guard let name = BubbleImages.save(image.data, mimeType: image.mimeType) else {
            OverlayLog.write("assistant image ignored: unreadable \(image.mimeType) payload")
            return
        }
        if forceNewAssistantRow {
            let item = ChatItem(
                kind: .assistant,
                text: "",
                imageNames: [name],
                assistantImagePlacements: [AssistantImagePlacement(name: name, textOffset: 0)]
            )
            forceNewAssistantRow = false
            streamingAssistantId = item.id
            items.append(item)
        } else if let id = streamingAssistantId,
           let index = items.firstIndex(where: { $0.id == id }) {
            appendAssistantImageName(name, to: &items[index])
        } else if let index = TranscriptStream.resumeAssistantIndex(kinds: items.map(\.kind.rawValue)) {
            appendAssistantImageName(name, to: &items[index])
            streamingAssistantId = items[index].id
        } else {
            let item = ChatItem(
                kind: .assistant,
                text: "",
                imageNames: [name],
                assistantImagePlacements: [AssistantImagePlacement(name: name, textOffset: 0)]
            )
            streamingAssistantId = item.id
            items.append(item)
        }
        persist()
    }

    private func appendImageName(_ name: String, to item: inout ChatItem) {
        var names = item.imageNames ?? []
        if !names.contains(name) { names.append(name) }
        item.imageNames = names
    }

    private func appendAssistantImageName(_ name: String, to item: inout ChatItem) {
        appendImageName(name, to: &item)
        var placements = item.assistantImagePlacements ?? []
        placements.append(AssistantImagePlacement(name: name, textOffset: item.text.count))
        item.assistantImagePlacements = placements
    }

    private func appendThought(_ raw: String) {
        pendingThoughtChunk += raw
        queueStreamFlush()
    }

    func setStreamUISuspended(_ suspended: Bool) {
        if streamUISuspended == suspended { return }
        streamUISuspended = suspended
        if !suspended {
            queueStreamFlush()
            if !childBusy,
               SideStagePolicy.shouldReloadWorkspacePaneOnResume(workspacePaneLoadState),
               let stage = workspaceStage,
               let sessionId = stage.sessionId,
               !sessionId.isEmpty,
               let item = items.first(where: { $0.id == stage.cardId }) {
                if workspacePaneItems.isEmpty {
                    workspacePanePresentationPhase = .waitingForContent
                }
                workspacePaneLoadState = .loading
                workspacePaneLoadGeneration += 1
                let generation = workspacePaneLoadGeneration
                startWorkspacePaneLoad(
                    from: item,
                    path: stage.path,
                    sessionId: sessionId,
                    generation: generation
                )
            }
        }
    }

    private func queueStreamFlush() {
        guard OverlayRenderPolicy.shouldFlushStreamToUI(
            overlayVisible: !streamUISuspended,
            isHiding: false
        ) else {
            streamFlushQueued = false
            return
        }
        guard !streamFlushQueued else { return }
        streamFlushQueued = true
        let renderedAssistantBytes = items.last(where: { $0.id == streamingAssistantId })?.text.utf8.count ?? 0
        let renderedThoughtBytes = items.last(where: { $0.id == streamingThoughtId })?.text.utf8.count ?? 0
        let interval = OverlayRenderPolicy.streamFlushInterval(
            renderedBytes: max(
                renderedAssistantBytes + pendingAssistantChunk.utf8.count,
                renderedThoughtBytes + pendingThoughtChunk.utf8.count
            )
        )
        let elapsed = ProcessInfo.processInfo.systemUptime - lastStreamFlushUptime
        let delay = max(0, interval - elapsed)
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self else { return }
            OverlayPulse.shared.onNextFrame { [weak self] in
                self?.flushStreamChunks()
            }
        }
    }

    private func flushStreamChunks() {
        streamFlushQueued = false
        lastStreamFlushUptime = ProcessInfo.processInfo.systemUptime
        let assistant = pendingAssistantChunk
        let thought = pendingThoughtChunk
        pendingAssistantChunk = ""
        pendingThoughtChunk = ""
        // Thoughts first so a same-frame thought lands above the answer.
        if !thought.isEmpty {
            commitThought(thought)
        }
        if !assistant.isEmpty {
            commitAssistant(assistant)
        }
    }

    private func commitAssistant(_ raw: String) {
        if forceNewAssistantRow {
            let cleaned = Self.stripDiagnostics(raw)
            guard !cleaned.isEmpty else { return }
            let item = ChatItem(kind: .assistant, text: cleaned)
            forceNewAssistantRow = false
            streamingAssistantId = item.id
            items.append(item)
            persist()
            return
        }
        if let id = streamingAssistantId,
           let index = items.firstIndex(where: { $0.id == id }) {
            applyAssistant(raw, at: index)
            return
        }
        if let index = TranscriptStream.resumeAssistantIndex(kinds: items.map(\.kind.rawValue)) {
            applyAssistant(raw, at: index)
            return
        }
        let cleaned = Self.stripDiagnostics(raw)
        guard !cleaned.isEmpty else { return }
        let item = ChatItem(kind: .assistant, text: cleaned)
        streamingAssistantId = item.id
        items.append(item)
        persist()
    }

    private func applyAssistant(_ raw: String, at index: Int) {
        let cleaned = Self.stripDiagnostics(items[index].text + raw)
        if cleaned.isEmpty {
            let id = items[index].id
            items.remove(at: index)
            if streamingAssistantId == id {
                streamingAssistantId = nil
            }
        } else {
            items[index].text = cleaned
            streamingAssistantId = items[index].id
        }
        persist()
    }

    private func commitThought(_ raw: String) {
        if let id = streamingThoughtId,
           let index = items.firstIndex(where: { $0.id == id }) {
            items[index].text = Self.stripDiagnostics(items[index].text + raw)
        } else {
            let cleaned = Self.stripDiagnostics(raw)
            guard !cleaned.isEmpty else { return }
            let item = ChatItem(kind: .thought, text: cleaned)
            streamingThoughtId = item.id
            items.append(item)
        }
        persist()
    }

    private func upsertTool(_ update: [String: Any], isUpdate: Bool) {
        streamingAssistantId = nil
        streamingThoughtId = nil
        let callId = update.string("toolCallId") ?? UUID().uuidString
        let title = update.string("title")
        let status = update.string("status")
        let kind = update.string("kind")
        let payload = extractToolPayload(update)
        let imageNames = persistedImageNames(payload.images)
        if let index = items.lastIndex(where: { $0.kind == .tool && $0.toolId == callId }) {
            if let title, !title.isEmpty {
                items[index].text = title
            }
            if let status {
                items[index].toolStatus = status
            }
            if let kind {
                items[index].toolKind = kind
            }
            if let input = payload.input, !input.isEmpty {
                items[index].toolInput = input
            }
            if let output = payload.output, !output.isEmpty {
                items[index].toolOutput = output
            }
            mergeImageNames(imageNames, into: &items[index])
        } else if !isUpdate || title != nil {
            items.append(
                ChatItem(
                    kind: .tool,
                    text: title ?? kind ?? "tool",
                    toolId: callId,
                    toolStatus: status ?? "pending",
                    toolKind: kind,
                    toolInput: payload.input,
                    toolOutput: payload.output,
                    imageNames: imageNames
                )
            )
        }
        persist()
        self.status = "tool"
    }

    private func extractToolPayload(
        _ update: [String: Any]
    ) -> (input: String?, output: String?, images: [AssistantMessageImage]) {
        var input = stringifyJSON(update["rawInput"])
        var chunks: [String] = []
        var images = AssistantMessageContent.images(in: update["rawOutput"])
        images.append(contentsOf: AssistantMessageContent.images(in: update["content"]))
        let structuredOutput = AssistantMessageContent.texts(in: update["rawOutput"])
            .joined(separator: "\n")
        if let rawOut = images.isEmpty
            ? stringifyJSON(update["rawOutput"])
            : (structuredOutput.isEmpty ? nil : structuredOutput) {
            chunks.append(rawOut)
        }
        if let content = update.array("content") {
            for entry in content {
                guard let object = JSONValue.object(entry) else { continue }
                switch object.string("type") {
                case "content":
                    if let text = extractText(object["content"]) {
                        chunks.append(text)
                    }
                case "diff":
                    let path = object.string("path") ?? "file"
                    let oldText = object.string("oldText") ?? ""
                    let newText = object.string("newText") ?? ""
                    chunks.append("diff \(path)\n---\n\(oldText)\n+++\n\(newText)")
                default:
                    if let text = extractText(object) ?? object.string("text") {
                        chunks.append(text)
                    }
                }
            }
        }
        if input == nil, let args = stringifyJSON(update["rawInput"] ?? update["arguments"]) {
            input = args
        }
        let output = chunks
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n")
        var uniqueImages: [AssistantMessageImage] = []
        for image in images where !uniqueImages.contains(image) {
            uniqueImages.append(image)
        }
        return (truncate(input), truncate(output.isEmpty ? nil : output), uniqueImages)
    }

    private func persistedImageNames(_ images: [AssistantMessageImage]) -> [String]? {
        var names: [String] = []
        for image in images {
            guard let name = BubbleImages.save(image.data, mimeType: image.mimeType),
                  !names.contains(name) else { continue }
            names.append(name)
        }
        return names.isEmpty ? nil : names
    }

    private func mergeImageNames(_ incoming: [String]?, into item: inout ChatItem) {
        guard let incoming else { return }
        var names = item.imageNames ?? []
        for name in incoming where !names.contains(name) { names.append(name) }
        item.imageNames = names
    }

    private func stringifyJSON(_ value: Any?) -> String? {
        guard let value, !(value is NSNull) else { return nil }
        if let string = value as? String {
            let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        if JSONSerialization.isValidJSONObject(value),
           let data = try? JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys]),
           let string = String(data: data, encoding: .utf8) {
            return string
        }
        return String(describing: value)
    }

    private func truncate(_ value: String?) -> String? {
        guard let value else { return nil }
        if value.count <= 12_000 { return value }
        return String(value.prefix(12_000)) + "\n…"
    }

    private func extractText(_ content: Any?) -> String? {
        if let string = content as? String { return string }
        if let object = JSONValue.object(content) {
            return object.string("text")
        }
        return nil
    }

    private func refreshConversationTree(
        expectedRunNonce: Int? = nil,
        expectedSessionID: String? = nil
    ) async {
        do {
            let snapshot = try await client.conversationTree()
            if let expectedRunNonce, expectedRunNonce != runNonce { return }
            if let expectedSessionID, expectedSessionID != client.sessionId { return }
            applyConversationTree(snapshot, replacingTranscript: false)
        } catch {
            OverlayLog.write("conversation tree refresh failed: \(friendly(error))")
        }
    }

    private func restoreConversationTree(replacingTranscript: Bool) async {
        do {
            var snapshot = try await client.conversationTree()
            if let sessionID = client.sessionId,
               let savedLeaf = Self.savedConversationLeaf(sessionID: sessionID),
               let restoredLeaf = snapshot.restoredLeafID(savedLeafID: savedLeaf),
               restoredLeaf != snapshot.leafID {
                snapshot = try await client.selectConversationLeaf(restoredLeaf)
            }
            applyConversationTree(snapshot, replacingTranscript: replacingTranscript)
        } catch {
            OverlayLog.write("conversation tree restore failed: \(friendly(error))")
        }
    }

    private func applyConversationTree(
        _ snapshot: ConversationTreeSnapshot,
        replacingTranscript: Bool,
        persistSelection: Bool = true
    ) {
        conversationTree = snapshot
        bindTranscriptSources(to: snapshot)
        if replacingTranscript {
            let existingItems = items
            cacheRichRows(items)
            var matchedLocalRows = Set<UUID>()
            let structuredRelayRunIDs = Set(snapshot.allWorkspaceRelayTexts.compactMap { text -> String? in
                guard let runId = WorkspaceRegistry.parseInjectionPrompt(
                          text,
                          home: OverlayPaths.home.path
                      )?.brief.runId,
                      !runId.isEmpty else { return nil }
                return runId
            })
            let projected = snapshot.transcript.map { record in
                if record.kind == .workspaceRelay {
                    return workspaceCard(
                        for: record,
                        existingItems: existingItems,
                        matchedLocalRows: &matchedLocalRows,
                        structuredRelayRunIDs: structuredRelayRunIDs
                    )
                }
                var projected = Self.chatItem(record)
                if let prior = richTranscriptRows[Self.richKey(entryID: record.entryID, kind: projected.kind)] {
                    var rich = prior
                    rich.text = projected.text
                    rich.toolStatus = projected.toolStatus ?? rich.toolStatus
                    rich.toolKind = projected.toolKind ?? rich.toolKind
                    rich.toolOutput = projected.toolOutput ?? rich.toolOutput
                    rich.imageNames = projected.imageNames ?? rich.imageNames
                    rich.sourceEntryId = record.entryID
                    rich.sourceBranchable = record.branchable
                    rich.deliveryState = nil
                    projected = rich
                }
                return projected
            }
            items = mergeBubbleOnlyRows(
                projected: projected,
                existing: existingItems,
                excluding: matchedLocalRows
            )
        } else {
            // Source bindings above are enough; live rows keep their richer local state.
        }
        cacheRichRows(items)
        if persistSelection, let sessionID = client.sessionId, let leafID = snapshot.leafID {
            var leaves = Self.savedConversationLeaves()
            leaves[sessionID] = leafID
            UserDefaults.standard.set(leaves, forKey: "bubble.conversation.leaves")
        }
        persist(immediate: true)
    }

    private func mergeBubbleOnlyRows(
        projected: [ChatItem],
        existing: [ChatItem],
        excluding excludedIDs: Set<UUID> = []
    ) -> [ChatItem] {
        let lastProjectedIndex = Dictionary(
            projected.enumerated().compactMap { index, item in
                item.sourceEntryId.map { ($0, index) }
            },
            uniquingKeysWith: { _, later in later }
        )
        var prefix: [ChatItem] = []
        var after: [Int: [ChatItem]] = [:]
        for (index, item) in existing.enumerated()
        where !excludedIDs.contains(item.id)
            && item.sourceEntryId == nil
            && (item.kind == .system || item.kind == .workspaceRun) {
            let anchor = existing[..<index].reversed().compactMap { prior -> Int? in
                guard let entryID = prior.sourceEntryId else { return nil }
                return lastProjectedIndex[entryID]
            }.first
            if let anchor {
                after[anchor, default: []].append(item)
            } else {
                prefix.append(item)
            }
        }
        var merged = prefix
        for (index, item) in projected.enumerated() {
            merged.append(item)
            merged.append(contentsOf: after[index] ?? [])
        }
        return merged
    }

    private func workspaceCard(
        for record: ConversationTranscriptRecord,
        existingItems: [ChatItem],
        matchedLocalRows: inout Set<UUID>,
        structuredRelayRunIDs: Set<String>
    ) -> ChatItem {
        guard let relay = WorkspaceRegistry.parseInjectionPrompt(record.text, home: OverlayPaths.home.path) else {
            return Self.chatItem(record)
        }
        let brief = relay.brief
        let availableCards = existingItems.filter {
            $0.kind == .workspaceRun && !matchedLocalRows.contains($0.id)
        }
        let exactRunCard = brief.runId.flatMap { runId in
            runId.isEmpty ? nil : availableCards.first(where: { $0.workspaceRunId == runId })
        }
        let legacyCard = brief.runId?.isEmpty != false ? availableCards.first(where: { item in
            WorkspaceRegistry.canMatchLegacyRelay(
                cardRunId: item.workspaceRunId,
                structuredRelayRunIds: structuredRelayRunIDs
            )
                && item.workspacePath.map(WorkspaceRegistry.normalize) == WorkspaceRegistry.normalize(brief.path)
                && item.workspaceGoal?.trimmingCharacters(in: .whitespacesAndNewlines)
                    == brief.goal.trimmingCharacters(in: .whitespacesAndNewlines)
        }) : nil
        let prior = richTranscriptRows[Self.richKey(entryID: record.entryID, kind: .workspaceRun)]
            ?? exactRunCard
            ?? legacyCard
        var card = prior ?? ChatItem(
            kind: .workspaceRun,
            text: brief.name,
            workspacePath: brief.path,
            workspaceName: brief.name,
            workspaceStatus: brief.status.rawValue,
            workspaceGoal: brief.goal,
            workspaceSummary: brief.summary,
            workspaceQuestion: brief.question,
            workspaceChangedPaths: brief.changedPaths,
            workspaceChildren: []
        )
        if let prior { matchedLocalRows.insert(prior.id) }
        card.text = brief.name
        card.workspacePath = brief.path
        card.workspaceName = brief.name
        card.workspaceStatus = brief.status.rawValue
        card.workspaceGoal = brief.goal
        card.workspaceSummary = brief.summary
        card.workspaceQuestion = brief.question
        card.workspaceChangedPaths = brief.changedPaths
        card.workspaceRunId = brief.runId ?? card.workspaceRunId
        card.workspaceSessionId = relay.sessionId ?? card.workspaceSessionId
        card.workspaceAnchorEntryId = relay.anchorEntryId ?? card.workspaceAnchorEntryId
        card.sourceEntryId = record.entryID
        card.sourceBranchable = false
        return card
    }

    private func bindTranscriptSources(to snapshot: ConversationTreeSnapshot) {
        for kind in [ChatItem.Kind.user, .thought, .assistant, .tool] {
            let source = snapshot.transcript.filter { Self.chatKind($0.kind) == kind }
            let local = items.indices.filter {
                items[$0].kind == kind
                    && items[$0].deliveryState == nil
                    && items[$0].sourceEntryId == nil
            }
            let count = min(source.count, local.count)
            guard count > 0 else { continue }
            for offset in 0..<count {
                let localIndex = local[local.count - count + offset]
                let record = source[source.count - count + offset]
                items[localIndex].sourceEntryId = record.entryID
                items[localIndex].sourceBranchable = record.branchable
            }
        }
    }

    private static func chatItem(_ record: ConversationTranscriptRecord) -> ChatItem {
        switch record.kind {
        case .user:
            return ChatItem(kind: .user, text: record.text, sourceEntryId: record.entryID, sourceBranchable: record.branchable)
        case .assistant:
            let restored = restoredImages(record.images, offsets: record.imageOffsets)
            return ChatItem(
                kind: .assistant,
                text: record.text,
                imageNames: restored.names,
                assistantImagePlacements: restored.placements,
                sourceEntryId: record.entryID,
                sourceBranchable: record.branchable
            )
        case .thought:
            return ChatItem(kind: .thought, text: record.text, sourceEntryId: record.entryID, sourceBranchable: record.branchable)
        case .tool:
            return ChatItem(
                kind: .tool,
                text: record.toolName ?? "Tool",
                toolId: record.toolCallID ?? record.entryID,
                toolStatus: record.isError ? "failed" : "completed",
                toolKind: record.toolName,
                toolOutput: record.text,
                imageNames: restoredImages(record.images, offsets: []).names,
                sourceEntryId: record.entryID,
                sourceBranchable: false
            )
        case .workspaceRelay:
            return ChatItem(
                kind: .workspaceRun,
                text: "Workspace",
                sourceEntryId: record.entryID,
                sourceBranchable: false
            )
        }
    }

    private static func restoredImages(
        _ images: [AssistantMessageImage],
        offsets: [Int]
    ) -> (names: [String]?, placements: [AssistantImagePlacement]?) {
        var names: [String] = []
        var placements: [AssistantImagePlacement] = []
        for (index, image) in images.enumerated() {
            guard let name = BubbleImages.save(image.data, mimeType: image.mimeType) else { continue }
            if !names.contains(name) { names.append(name) }
            if offsets.indices.contains(index) {
                placements.append(AssistantImagePlacement(name: name, textOffset: offsets[index]))
            }
        }
        return (
            names.isEmpty ? nil : names,
            placements.isEmpty ? nil : placements
        )
    }

    private static func chatKind(_ kind: ConversationTranscriptRecord.Kind) -> ChatItem.Kind {
        switch kind {
        case .user: .user
        case .assistant: .assistant
        case .thought: .thought
        case .tool: .tool
        case .workspaceRelay: .workspaceRun
        }
    }

    private func cacheRichRows(_ rows: [ChatItem]) {
        for item in rows {
            guard let key = Self.richKey(item) else { continue }
            richTranscriptRows[key] = item
        }
    }

    private static func richKey(_ item: ChatItem) -> String? {
        guard let entryID = item.sourceEntryId else { return nil }
        return richKey(entryID: entryID, kind: item.kind)
    }

    private static func richKey(entryID: String, kind: ChatItem.Kind) -> String {
        "\(entryID)|\(kind.rawValue)"
    }

    private static func savedConversationLeaves() -> [String: String] {
        UserDefaults.standard.dictionary(forKey: "bubble.conversation.leaves") as? [String: String] ?? [:]
    }

    private static func savedConversationLeaf(sessionID: String) -> String? {
        if let leaf = savedConversationLeaves()[sessionID] { return leaf }
        let url = transcriptURL(sessionID: sessionID)
        let data = (try? Data(contentsOf: url)) ?? (try? Data(contentsOf: OverlayPaths.transcriptFile))
        guard let data,
              let envelope = try? JSONDecoder().decode(TranscriptEnvelope.self, from: data),
              envelope.sessionId == sessionID else { return nil }
        return envelope.selectedLeafId
    }

    private func branchTitle(_ text: String) -> String {
        let title = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? "message"
        return title.count > 42 ? String(title.prefix(41)) + "…" : title
    }

    private func persist(immediate: Bool = false) {
        transcriptRevision &+= 1
        if !immediate,
           !OverlayRenderPolicy.shouldPersistStreamChunk(isBusy: isBusy, childBusy: childBusy) {
            return
        }
        if items.count > TranscriptVirtualizationLimits.retainedItems {
            items = Array(items.suffix(TranscriptVirtualizationLimits.retainedItems))
        }
        persistWork?.cancel()
        let write = DispatchWorkItem { [weak self] in
            self?.writeTranscript()
        }
        persistWork = write
        if immediate {
            writeTranscript()
        } else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: write)
        }
    }

    private func writeTranscript() {
        guard !transcriptRestorePending else { return }
        guard let sessionID = client.sessionId ?? PiSessions.currentId() else { return }
        let itemSnapshot = items
        let richSnapshot = richTranscriptRows
        let selectedLeafID = Self.savedConversationLeaves()[sessionID]
        let sessionURL = Self.transcriptURL(sessionID: sessionID)
        let transcriptURL = OverlayPaths.transcriptFile
        let writesCurrentTranscript = runtimeRole.persistsAsMain
        Self.transcriptPersistQueue.async {
            do {
                let stored = itemSnapshot
                    .suffix(TranscriptVirtualizationLimits.retainedItems)
                    .filter { item in
                        if item.kind == .assistant || item.kind == .thought {
                            return item.kind == .assistant
                                ? AssistantMessagePresentation.hasContent(
                                    text: item.text,
                                    imageNames: item.imageNames
                                )
                                : !item.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        }
                        return true
                    }
                let envelope = TranscriptEnvelope(
                    sessionId: sessionID,
                    selectedLeafId: selectedLeafID,
                    items: Array(stored),
                    richItems: Array(richSnapshot.values.suffix(TranscriptVirtualizationLimits.retainedItems))
                )
                let data = try JSONEncoder().encode(envelope)
                try FileManager.default.createDirectory(
                    at: sessionURL.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try data.write(to: sessionURL, options: .atomic)
                if writesCurrentTranscript {
                    try data.write(to: transcriptURL, options: .atomic)
                }
            } catch {
                OverlayLog.write("transcript save failed: \(error.localizedDescription)")
            }
        }
    }

    private func restoreTranscriptInBackground(sessionID: String) {
        transcriptLoadGeneration &+= 1
        transcriptRestorePending = true
        TranscriptHydrationTiming.startIfDiagnosing()
        let generation = transcriptLoadGeneration
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            let restored = await Self.loadTranscriptOffMain(sessionID: sessionID)
            defer {
                if self.transcriptLoadGeneration == generation {
                    self.transcriptRestoreTask = nil
                }
            }
            guard self.transcriptLoadGeneration == generation else { return }
            self.transcriptRestorePending = false
            guard
                  self.client.sessionId == sessionID
                    || (self.client.sessionId == nil && PiSessions.currentId() == sessionID) else { return }
            self.mergeRestoredTranscript(restored, removingSetupCards: true)
            self.writeTranscript()
            self.onTranscriptUpdated?()
        }
        transcriptRestoreTask = task
    }

    private func finishPendingTranscriptRestore() {
        guard transcriptRestorePending else { return }
        transcriptLoadGeneration &+= 1
        transcriptRestorePending = false
        guard let sessionID = client.sessionId ?? PiSessions.currentId() else { return }
        mergeRestoredTranscript(
            Self.loadTranscript(sessionID: sessionID),
            removingSetupCards: runtimeRole.restoresSavedTranscript
        )
    }

    private func mergeRestoredTranscript(
        _ restored: TranscriptLoadResult,
        removingSetupCards: Bool
    ) {
        let restoredItems = restored.items.filter { item in
            !removingSetupCards
                || !StartupTranscriptPolicy.isSetupCard(item.text, isSystem: item.kind == .system)
        }
        items = TranscriptRestoreMerge.merge(
            restored: restoredItems,
            live: items,
            id: \.id,
            stableKey: Self.richKey
        )
        richTranscriptRows = [:]
        for item in restored.richItems + restored.items + items {
            if let key = Self.richKey(item) { richTranscriptRows[key] = item }
        }
        Self.prewarmTranscriptChunks(Array(items[transcriptHistoryLowerBound...]))
    }

    private static func loadTranscriptOffMain(sessionID: String) async -> TranscriptLoadResult {
        await withCheckedContinuation { continuation in
            transcriptLoadQueue.async {
                continuation.resume(returning: loadTranscript(sessionID: sessionID))
            }
        }
    }

    private static func prewarmTranscriptChunks(_ items: [ChatItem]) {
        let assistantRows = items.compactMap { item -> (String, String)? in
            guard item.kind == .assistant,
                  (item.imageNames ?? []).isEmpty else { return nil }
            return (item.id.uuidString, item.text)
        }
        guard !assistantRows.isEmpty else { return }
        transcriptWarmupQueue.async {
            for (id, text) in assistantRows {
                _ = WorkspaceTranscriptChunker.chunks(text, identity: id)
            }
        }
    }

    private static func loadTranscript(sessionID: String) -> TranscriptLoadResult {
        let sessionData = try? Data(contentsOf: transcriptURL(sessionID: sessionID))
        let currentData = try? Data(contentsOf: OverlayPaths.transcriptFile)
        let envelope = [sessionData, currentData].compactMap { data -> TranscriptEnvelope? in
            guard let data,
                  let decoded = try? JSONDecoder().decode(TranscriptEnvelope.self, from: data),
                  decoded.sessionId == sessionID else { return nil }
            return decoded
        }.first
        let clean: ([ChatItem]) -> [ChatItem] = { rows in rows.compactMap { item in
            var copy = item
            copy.deliveryState = nil
            if StartupTranscriptPolicy.isTransientInternalError(
                copy.text,
                isSystem: copy.kind == .system
            ) {
                return nil
            }
            if copy.kind == .assistant || copy.kind == .thought {
                copy.text = stripDiagnostics(copy.text)
                if copy.kind == .assistant {
                    if !AssistantMessagePresentation.hasContent(
                        text: copy.text,
                        imageNames: copy.imageNames
                    ) { return nil }
                } else if copy.text.isEmpty {
                    return nil
                }
            } else if copy.kind == .system, copy.text == "Started a fresh session." {
                copy.text = "Bubble is ready."
            }
            return copy
        } }
        if let envelope {
            return TranscriptLoadResult(
                items: repairTranscript(clean(envelope.items)),
                richItems: clean(envelope.richItems ?? [])
            )
        }
        // Migrate the pre-envelope transcript once. The legacy file belonged to
        // the session recorded in session-id, and the next write scopes it by ID.
        if let currentData,
           PiSessions.currentId() == sessionID,
           let legacy = try? JSONDecoder().decode([ChatItem].self, from: currentData) {
            let migrated = repairTranscript(clean(legacy))
            return TranscriptLoadResult(items: migrated, richItems: migrated)
        }
        return TranscriptLoadResult(items: [], richItems: [])
    }

    private static func transcriptURL(sessionID: String) -> URL {
        let safe = sessionID.map { character -> Character in
            character.isLetter || character.isNumber || character == "-" || character == "_" ? character : "_"
        }
        return OverlayPaths.root
            .appendingPathComponent("transcripts", isDirectory: true)
            .appendingPathComponent(String(safe) + ".json")
    }

    static func repairTranscript(_ items: [ChatItem]) -> [ChatItem] {
        var result: [ChatItem] = []
        for var item in items {
            if item.kind == .workspaceRun {
                item.workspaceChildren = coalesceWorkspaceChildren(item.workspaceChildren ?? [])
                let incoming = workspaceRunRecord(item)
                if let duplicate = result.firstIndex(where: {
                    $0.kind == .workspaceRun
                        && TranscriptStream.areDuplicateWorkspaceRuns(workspaceRunRecord($0), incoming)
                }) {
                    result[duplicate] = mergeWorkspaceRun(result[duplicate], item)
                    continue
                }
            }
            if let last = result.indices.last,
               TranscriptStream.canMergeAdjacent(
                previous: result[last].kind.rawValue,
                next: item.kind.rawValue
               ) {
                result[last].text = TranscriptStream.joinText(result[last].text, item.text)
                result[last].imageNames = Self.mergedImageNames(
                    result[last].imageNames,
                    item.imageNames
                )
                continue
            }
            if let last = result.indices.last,
               result[last].kind == .assistant,
               item.kind == .assistant,
               TranscriptStream.shouldGlueSplitAssistant(result[last].text, item.text) {
                result[last].text = TranscriptStream.joinText(result[last].text, item.text)
                result[last].imageNames = Self.mergedImageNames(
                    result[last].imageNames,
                    item.imageNames
                )
                continue
            }
            result.append(item)
        }
        let assistantIndices = result.indices.filter { result[$0].kind == .assistant }
        let repairedTexts = TranscriptStream.repairedAssistantTexts(
            assistantIndices.map { result[$0].text }
        )
        for (index, text) in zip(assistantIndices, repairedTexts) {
            result[index].text = text
        }
        return result.filter { item in
            if item.kind == .assistant {
                return AssistantMessagePresentation.hasContent(
                    text: item.text,
                    imageNames: item.imageNames
                )
            }
            return true
        }
    }

    private static func mergedImageNames(_ left: [String]?, _ right: [String]?) -> [String]? {
        let names = (left ?? []) + (right ?? [])
        guard !names.isEmpty else { return nil }
        return Array(NSOrderedSet(array: names)) as? [String]
    }

    private static func workspaceRunRecord(_ item: ChatItem) -> TranscriptStream.WorkspaceRunRecord {
        TranscriptStream.WorkspaceRunRecord(
            path: item.workspacePath ?? "",
            runId: item.workspaceRunId,
            sessionId: item.workspaceSessionId,
            goal: item.workspaceGoal ?? "",
            status: item.workspaceStatus,
            summary: item.workspaceSummary ?? "",
            anchorEntryId: item.workspaceAnchorEntryId
        )
    }

    private static func mergeWorkspaceRun(_ earlier: ChatItem, _ later: ChatItem) -> ChatItem {
        var merged = earlier
        merged.workspaceAnchorEntryId = earlier.workspaceAnchorEntryId ?? later.workspaceAnchorEntryId
        merged.workspaceRunId = earlier.workspaceRunId ?? later.workspaceRunId
        merged.workspaceSessionId = earlier.workspaceSessionId ?? later.workspaceSessionId
        if later.text.count > earlier.text.count { merged.text = later.text }
        if (later.workspaceName?.count ?? 0) > (earlier.workspaceName?.count ?? 0) {
            merged.workspaceName = later.workspaceName
        }
        if (later.workspaceGoal?.count ?? 0) > (earlier.workspaceGoal?.count ?? 0) {
            merged.workspaceGoal = later.workspaceGoal
        }
        if (later.workspaceSummary?.count ?? 0) > (earlier.workspaceSummary?.count ?? 0) {
            merged.workspaceSummary = later.workspaceSummary
        }
        if (later.workspaceQuestion?.count ?? 0) > (earlier.workspaceQuestion?.count ?? 0) {
            merged.workspaceQuestion = later.workspaceQuestion
        }
        if let status = later.workspaceStatus, !status.isEmpty {
            merged.workspaceStatus = status
        }
        let changed = (earlier.workspaceChangedPaths ?? []) + (later.workspaceChangedPaths ?? [])
        if !changed.isEmpty {
            merged.workspaceChangedPaths = Array(NSOrderedSet(array: changed)) as? [String]
        }
        if let left = earlier.workspaceStartedAt, let right = later.workspaceStartedAt {
            merged.workspaceStartedAt = min(left, right)
        } else {
            merged.workspaceStartedAt = earlier.workspaceStartedAt ?? later.workspaceStartedAt
        }
        if (later.workspaceChildren?.count ?? 0) > (earlier.workspaceChildren?.count ?? 0) {
            merged.workspaceChildren = later.workspaceChildren
        }
        return merged
    }

    private static func coalesceWorkspaceChildren(_ children: [ChatItem]) -> [ChatItem] {
        var result: [ChatItem] = []
        for item in children {
            if item.kind == .thought,
               item.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                continue
            }
            if TranscriptStream.shouldMergeThought(previousKind: result.last?.kind.rawValue),
               item.kind == .thought {
                result[result.count - 1].text = TranscriptStream.joinText(
                    result[result.count - 1].text,
                    item.text
                )
                continue
            }
            result.append(item)
        }
        return TranscriptStream.cappedChildren(result)
    }

    static func stripDiagnostics(_ text: String) -> String {
        if isPiStartupMetadata(text) {
            return ""
        }
        var result = text
        let patterns = [
            #"\[context\][^\n]*"#,
            #"(?i)bytes effective=\d+[^\n]*"#,
            #"(?i)skill_(description|catalog)_bytes[^\n]*"#,
            #"(?i)override with --context-limit[^\n]*"#,
        ]
        for pattern in patterns {
            result = result.replacingOccurrences(of: pattern, with: "", options: .regularExpression)
        }
        result = result.replacingOccurrences(of: #"\n{3,}"#, with: "\n\n", options: .regularExpression)
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func isPiStartupMetadata(_ text: String) -> Bool {
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalized.range(
            of: #"(?i)^pi v\d+(?:\.\d+)+(?:\s|$)"#,
            options: .regularExpression
        ) != nil else {
            return false
        }
        return normalized.contains("\n## Context\n")
            && normalized.contains("\n## Skills\n")
    }

    private func friendly(_ error: Error) -> String {
        let text = error.localizedDescription
        let lowered = text.lowercased()
        if lowered.contains("auth") || lowered.contains("credential") || lowered.contains("api key") {
            return "Pi needs a signed-in provider. Type /login in Bubble."
        }
        if lowered.contains("pi not found") || lowered.contains("pi-acp not found") {
            return text
        }
        return text
    }

    private func clearActiveWorkspaceRun() {
        workspaceRunGeneration += 1
        if childBusy, let id = childSessionId {
            client.cancel(sessionId: id)
        }
        childBusy = false
        childSessionId = nil
        hushMainAssistant = false
        injecting = false
        pendingInjection = nil
        pendingChildSteer = nil
        guard workspaceState.active != nil else { return }
        workspaceState.active = nil
        persistWorkspaceState()
    }

    private func interruptActiveWorkspaceRun(_ active: WorkspaceBrief) {
        let pending = pendingChildSteer
        workspaceRunGeneration += 1
        if let id = childSessionId {
            client.cancel(sessionId: id)
        }
        childBusy = false
        childSessionId = nil
        hushMainAssistant = false
        pendingChildSteer = nil
        var interrupted = active
        interrupted.status = .interrupted
        interrupted.question = nil
        if interrupted.summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            interrupted.summary = "Cancelled."
        }
        workspaceState.active = interrupted
        persistWorkspaceState()
        upsertWorkspaceCard(interrupted)
        if let pending {
            recordUnstartedWorkspaceFollowUp(
                pending,
                status: .interrupted,
                summary: "Not started because the preceding workspace run was cancelled."
            )
        }
    }

    private func recordUnstartedWorkspaceFollowUp(
        _ brief: WorkspaceBrief,
        status: WorkspaceStatus,
        summary: String
    ) {
        var terminal = brief
        terminal.status = status
        terminal.summary = summary
        terminal.question = nil
        upsertWorkspaceCard(terminal)
        if let index = items.lastIndex(where: {
            $0.kind == .workspaceRun && $0.workspaceRunId == terminal.runId
        }) {
            items[index].workspaceSessionId = nil
            items[index].workspaceAnchorEntryId = nil
            persist()
        }
    }

    private func resetWorkspaceSessionsForFreshMainSession() throws {
        WorkspaceRegistry.resetSessions(in: &workspaceState)
        childSessionId = nil
        childSessionIds.removeAll()
        workspacePaneAttachedSessionIds.removeAll()
        workspacePaneRowsBySession.removeAll()
        workspacePaneRowsByRun.removeAll()
        workspacePaneRunCacheOrder.removeAll()
        workspacePaneInvalidatedSessionIds.removeAll()
        try persistWorkspaceStateOrThrow()
    }

    private func persistWorkspaceState() {
        do {
            try persistWorkspaceStateOrThrow()
        } catch {
            OverlayLog.write("mounts save failed: \(error.localizedDescription)")
        }
    }

    private func persistWorkspaceStateOrThrow() throws {
        guard runtimeRole.persistsWorkspaceRegistry else {
            refreshMountSkills()
            macEpoch += 1
            return
        }
        try WorkspaceRegistry.save(workspaceState, to: OverlayPaths.mountsFile)
        refreshMountSkills()
        macEpoch += 1
    }

    private func refreshMountSkills() {
        mountSkillRefreshGeneration += 1
        let generation = mountSkillRefreshGeneration
        let paths = workspaceState.mounts.map(\.path)
        Self.catalogRefreshQueue.async { [weak self] in
            var map: [String: [String]] = [:]
            for path in paths {
                map[path] = PiCatalog.projectSkillNames(at: URL(fileURLWithPath: path))
            }
            DispatchQueue.main.async {
                guard let self, self.mountSkillRefreshGeneration == generation else { return }
                self.mountSkillNames = map
                self.macEpoch += 1
            }
        }
    }

    @discardableResult
    private func toggleMount(_ path: String) throws -> String {
        let action = try WorkspaceRegistry.toggle(
            path: path,
            in: &workspaceState,
            bubbleRoot: OverlayPaths.root.path,
            workspace: OverlayPaths.workspace.path
        )
        persistWorkspaceState()
        return action
    }

    private func mountMessage(action: String, path: String) -> String {
        let shown = WorkspaceRegistry.displayPath(path, home: OverlayPaths.home.path)
        if action == "mounted" {
            return "Mounted \(shown)"
        }
        return "Unmounted \(shown)"
    }

    private func handleMountPalette(_ item: PaletteItem, preferEnter: Bool) {
        let role = item.role ?? "enter"
        if role == "browse" || item.insert == WorkspaceRegistry.browseSentinel {
            browseMountFolder()
            return
        }
        if role == "up" || item.insert == WorkspaceRegistry.parentSentinel {
            leaveMountFolder()
            return
        }
        if preferEnter, role == "enter" {
            draft = "/mounts \(WorkspaceRegistry.enterQuery(path: item.insert, home: OverlayPaths.home))"
            paletteSuppressed = false
            slashHighlight = 0
            requestFocus()
            return
        }
        do {
            let action = try toggleMount(item.insert)
            items.append(ChatItem(kind: .system, text: mountMessage(action: action, path: item.insert)))
            persist(immediate: true)
        } catch {
            items.append(ChatItem(kind: .system, text: error.localizedDescription))
            persist(immediate: true)
        }
        if !draft.hasPrefix("/mounts") {
            draft = "/mounts "
        }
        paletteSuppressed = false
        requestFocus()
    }

    private func browseMountFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = OverlayPaths.home
        panel.prompt = "Mount"
        guard panel.runModal() == .OK, let url = panel.url else {
            requestFocus()
            return
        }
        do {
            let action = try toggleMount(url.path)
            items.append(ChatItem(kind: .system, text: mountMessage(action: action, path: url.path)))
            persist(immediate: true)
        } catch {
            items.append(ChatItem(kind: .system, text: error.localizedDescription))
            persist(immediate: true)
        }
        draft = "/mounts \(WorkspaceRegistry.enterQuery(path: url.path, home: OverlayPaths.home))"
        paletteSuppressed = false
        requestFocus()
    }

    private func handleWorkspaceControl(_ method: String, _ params: [String: Any]) async throws -> [String: Any] {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.main.async {
                Task {
                    do {
                        let result = try await self.dispatchWorkspaceControl(method, params)
                        continuation.resume(returning: result)
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
            }
        }
    }

    private func dispatchWorkspaceControl(_ method: String, _ params: [String: Any]) async throws -> [String: Any] {
        switch method {
        case "workspace_run":
            let mount = params.string("mount") ?? ""
            let prompt = params.string("prompt") ?? ""
            return try await workspaceRun(mount: mount, prompt: prompt)
        case "workspace_cancel":
            return try workspaceCancel()
        case "mount_workspace":
            let path = WorkspaceRegistry.expandPath(params.string("path") ?? "", home: OverlayPaths.home)
            try WorkspaceRegistry.mount(
                path: path,
                in: &workspaceState,
                bubbleRoot: OverlayPaths.root.path,
                workspace: OverlayPaths.workspace.path
            )
            persistWorkspaceState()
            return ["status": "mounted", "path": path, "name": WorkspaceRegistry.displayName(path: path)]
        case "unmount_workspace":
            let raw = params.string("path") ?? ""
            let mount = WorkspaceRegistry.resolve(raw, in: workspaceState, home: OverlayPaths.home)
            let path = mount?.path ?? WorkspaceRegistry.expandPath(raw, home: OverlayPaths.home)
            try WorkspaceRegistry.unmount(path: path, in: &workspaceState)
            persistWorkspaceState()
            return ["status": "unmounted", "path": path]
        default:
            throw RPCError(code: -20, message: "unknown workspace method \(method)")
        }
    }

    private func workspaceRun(mount raw: String, prompt: String) async throws -> [String: Any] {
        guard let resolved = WorkspaceRegistry.resolve(raw, in: workspaceState, home: OverlayPaths.home) else {
            throw WorkspaceError.notMounted
        }
        if injecting {
            throw RPCError(
                code: -21,
                message: "The workspace run already finished. Do not call workspace_run. Reply to the user now with no tools."
            )
        }
        if let active = workspaceState.active, active.isActive, active.path != resolved.path {
            throw WorkspaceError.otherRunning(active.name)
        }
        let brief = WorkspaceBrief(
            runId: UUID().uuidString,
            path: resolved.path,
            name: resolved.name,
            status: .running,
            goal: prompt,
            summary: activeWorkspaceBrief?.path == resolved.path ? (activeWorkspaceBrief?.summary ?? "") : ""
        )
        let runId = brief.runId ?? ""
        let generation = workspaceRunGeneration
        if !WorkspaceRunLifecyclePolicy.shouldPrepareSession(childBusy: childBusy) {
            pendingChildSteer = brief
            return [
                "status": "started",
                "name": resolved.name,
                "path": resolved.path,
                "note": "queued follow-up on the running workspace",
            ]
        }
        hushMainAssistant = true
        workspaceState.active = brief
        persistWorkspaceState()
        upsertWorkspaceCard(brief)
        childBusy = true
        childAssistant = ""
        childChanged = []
        followOpenWorkspaceStageIfNeeded(brief)
        Task { @MainActor in
            await self.prepareAndRunWorkspace(
                brief: brief,
                prompt: prompt,
                mount: resolved,
                generation: generation,
                runId: runId
            )
        }
        return [
            "status": "started",
            "name": resolved.name,
            "path": resolved.path,
        ]
    }

    private func prepareAndRunWorkspace(
        brief: WorkspaceBrief,
        prompt: String,
        mount: WorkspaceMount,
        generation: Int,
        runId: String
    ) async {
        do {
            if !isConnected {
                await connect()
                guard isConnected else {
                    throw RPCError(code: -4, message: "not connected")
                }
            }
            guard WorkspaceRunLifecyclePolicy.acceptsCompletion(
                expectedGeneration: generation,
                currentGeneration: workspaceRunGeneration,
                expectedRunId: runId,
                activeRunId: workspaceState.active?.runId
            ) else { return }
            let sessionId = try await ensureChildSession(mount)
            guard WorkspaceRunLifecyclePolicy.acceptsCompletion(
                expectedGeneration: generation,
                currentGeneration: workspaceRunGeneration,
                expectedRunId: runId,
                activeRunId: workspaceState.active?.runId
            ) else { return }
            childSessionId = sessionId
            childSessionIds.insert(sessionId)
            WorkspaceRegistry.rememberSession(path: mount.path, sessionId: sessionId, in: &workspaceState)
            invalidateWorkspacePaneSession(sessionId)
            persistWorkspaceState()
            if let index = items.lastIndex(where: {
                $0.kind == .workspaceRun && $0.workspaceRunId == brief.runId
            }) {
                items[index].workspaceSessionId = sessionId
                persist()
                if SideStagePolicy.shouldRebindResolvedWorkspaceSession(
                    currentMountPath: workspaceStage?.path,
                    currentRunId: workspaceStage?.runId,
                    showingFilePreview: filePreview != nil,
                    resolvedMountPath: mount.path,
                    resolvedRunId: runId
                ) {
                    openWorkspaceStage(from: items[index])
                }
            }
            try? await client.applyBubblePreferences(sessionId: sessionId)
            guard WorkspaceRunLifecyclePolicy.acceptsCompletion(
                expectedGeneration: generation,
                currentGeneration: workspaceRunGeneration,
                expectedRunId: runId,
                activeRunId: workspaceState.active?.runId
            ) else { return }
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 350_000_000)
                await self.captureWorkspaceAnchor(
                    sessionId: sessionId,
                    goal: prompt,
                    path: mount.path,
                    generation: generation,
                    runId: runId
                )
            }
            await awaitChildPrompt(
                sessionId: sessionId,
                prompt: prompt,
                mount: mount,
                generation: generation,
                runId: runId
            )
        } catch {
            OverlayLog.write("workspace preparation failed: \(error.localizedDescription)")
            finishChildRun(
                stopReason: "failed",
                mount: mount,
                error: error.localizedDescription,
                generation: generation,
                runId: runId
            )
        }
    }

    private func ensureChildSession(_ mount: WorkspaceMount) async throws -> String {
        let cwd = URL(fileURLWithPath: mount.path)
        if let existing = mount.sessionId, !existing.isEmpty {
            if try await client.attach(existing, cwd: cwd) {
                return existing
            }
        }
        return try await client.createSession(cwd: cwd)
    }

    private func awaitChildPrompt(
        sessionId: String,
        prompt: String,
        mount: WorkspaceMount,
        generation: Int,
        runId: String
    ) async {
        do {
            let stop = try await client.prompt(prompt, sessionId: sessionId)
            finishChildRun(
                stopReason: stop,
                mount: mount,
                generation: generation,
                runId: runId
            )
        } catch {
            OverlayLog.write("workspace run failed: \(error.localizedDescription)")
            finishChildRun(
                stopReason: "failed",
                mount: mount,
                error: error.localizedDescription,
                generation: generation,
                runId: runId
            )
        }
    }

    private func finishChildRun(
        stopReason: String,
        mount: WorkspaceMount,
        error: String? = nil,
        generation: Int,
        runId: String
    ) {
        guard WorkspaceRunLifecyclePolicy.acceptsCompletion(
            expectedGeneration: generation,
            currentGeneration: workspaceRunGeneration,
            expectedRunId: runId,
            activeRunId: workspaceState.active?.runId
        ) else { return }
        defer {
            if !runId.isEmpty {
                removeWorkspaceRunRows(runId: runId)
            }
        }
        var unstartedFollowUp: WorkspaceBrief?
        if var pending = pendingChildSteer,
           stopReason == "cancelled" || error != nil || stopReason == "failed" {
            pending.question = nil
            if stopReason == "cancelled" {
                pending.status = .interrupted
                pending.summary = "Not started because the preceding workspace run was cancelled."
            } else {
                pending.status = .failed
                let reason = error?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                pending.summary = reason.isEmpty
                    ? "Not started because the preceding workspace run failed."
                    : "Not started because the preceding workspace run failed: \(reason)"
            }
            unstartedFollowUp = pending
        }
        childBusy = false
        if stopReason != "cancelled", error == nil, let next = pendingChildSteer {
            pendingChildSteer = nil
            childBusy = true
            childAssistant = ""
            childChanged = []
            if let childSessionId {
                invalidateWorkspacePaneSession(childSessionId)
            }
            workspaceState.active = next
            persistWorkspaceState()
            upsertWorkspaceCard(next)
            let sessionId = childSessionId
            let nextRunId = next.runId ?? ""
            Task { @MainActor in
                guard let sessionId else { return }
                await self.awaitChildPrompt(
                    sessionId: sessionId,
                    prompt: next.goal,
                    mount: mount,
                    generation: generation,
                    runId: nextRunId
                )
            }
            Task { @MainActor in
                guard let sessionId else { return }
                try? await Task.sleep(nanoseconds: 350_000_000)
                await self.captureWorkspaceAnchor(
                    sessionId: sessionId,
                    goal: next.goal,
                    path: mount.path,
                    generation: generation,
                    runId: nextRunId
                )
            }
            return
        }
        pendingChildSteer = nil
        var brief = workspaceState.active ?? WorkspaceBrief(
            path: mount.path,
            name: mount.name,
            status: .done,
            goal: ""
        )
        if stopReason == "cancelled" {
            brief.status = .interrupted
            brief.summary = WorkspaceRegistry.clip(childAssistant.isEmpty ? "Cancelled." : childAssistant, WorkspaceRegistry.maxSummaryChars)
        } else if error != nil || stopReason == "failed" {
            brief.status = .failed
            brief.summary = WorkspaceRegistry.clip(error ?? childAssistant, WorkspaceRegistry.maxSummaryChars)
        } else {
            brief.summary = WorkspaceRegistry.clip(childAssistant, WorkspaceRegistry.maxSummaryChars)
            brief.changedPaths = Array(
                FileChangeSummaryPolicy.uniqueDisplayPaths(
                    childChanged,
                    workspaceRoot: brief.path
                ).prefix(WorkspaceRegistry.maxChangedPaths)
            )
            if let question = WorkspaceRegistry.inferWaiting(from: brief.summary) {
                brief.status = .waiting
                brief.question = question
            } else {
                brief.status = .done
                brief.question = nil
            }
        }
        workspaceState.active = brief
        persistWorkspaceState()
        upsertWorkspaceCard(brief)
        if let unstartedFollowUp {
            recordUnstartedWorkspaceFollowUp(
                unstartedFollowUp,
                status: unstartedFollowUp.status,
                summary: unstartedFollowUp.summary
            )
        }
        if workspacePaneIsCurrent(path: mount.path),
           let item = items.last(where: { $0.kind == .workspaceRun && $0.workspacePath == mount.path }),
           workspaceStage?.cardId == item.id,
           let sessionId = item.workspaceSessionId ?? childSessionId {
            workspacePaneStreamingAssistantId = nil
            workspacePaneStreamingThoughtId = nil
            workspacePaneItems = [ChatItem(kind: .system, text: Self.workspacePaneLoadingText)]
            workspacePaneLoadState = .loading
            workspacePaneLoadGeneration += 1
            let generation = workspacePaneLoadGeneration
            startWorkspacePaneLoad(
                from: item,
                path: mount.path,
                sessionId: sessionId,
                generation: generation
            )
        }
        OverlayLog.write("workspace run \(brief.status.rawValue) \(brief.name)")
        if isBusy && !injecting {
            OverlayLog.write("ending parent turn after workspace result")
            cancel()
        }
        enqueueInjection(brief)
    }

    @discardableResult
    private func workspaceCancel() throws -> [String: Any] {
        guard let active = workspaceState.active, active.isActive else {
            throw WorkspaceError.noActiveRun
        }
        interruptActiveWorkspaceRun(active)
        return ["status": "cancelling", "name": active.name]
    }

    func cancelWorkspaceRun() {
        let parentBusy = injecting || isBusy
        if let active = workspaceState.active, active.isActive {
            interruptActiveWorkspaceRun(active)
        } else {
            clearActiveWorkspaceRun()
        }
        if parentBusy {
            cancel()
        }
        OverlayLog.write("stopped workspace run from UI")
    }

    private func enqueueInjection(_ brief: WorkspaceBrief) {
        if isBusy || injecting {
            pendingInjection = brief
            return
        }
        injectBrief(brief)
    }

    private func flushPendingInjection() {
        guard let brief = pendingInjection else { return }
        pendingInjection = nil
        injectBrief(brief)
    }

    private func injectBrief(_ brief: WorkspaceBrief) {
        injecting = true
        injectSpoke = false
        hushMainAssistant = false
        isBusy = true
        status = "thinking"
        turnStartedAt = Date()
        runNonce += 1
        let nonce = runNonce
        Task { @MainActor in
            do {
                if !isConnected {
                    await connect()
                }
                let relaySessionID = client.sessionId
                let card = items.last(where: {
                    $0.kind == .workspaceRun && $0.workspaceRunId == brief.runId
                })
                let text = WorkspaceRegistry.injectionPrompt(
                    brief,
                    home: OverlayPaths.home.path,
                    sessionId: card?.workspaceSessionId ?? childSessionId,
                    anchorEntryId: card?.workspaceAnchorEntryId
                )
                _ = try await client.prompt(text)
                guard nonce == self.runNonce else { return }
                status = "ready"
                // The relay is a real continuation of the main Pi session.
                // Refresh its leaf before persisting so a later restore cannot
                // stop at the preceding workspace tool call.
                await refreshConversationTree(
                    expectedRunNonce: nonce,
                    expectedSessionID: relaySessionID
                )
            } catch {
                guard nonce == self.runNonce else { return }
                items.append(ChatItem(kind: .system, text: friendly(error)))
                persist(immediate: true)
                status = friendly(error)
            }
            guard nonce == self.runNonce else { return }
            if !injectSpoke {
                let fallback = brief.summary.trimmingCharacters(in: .whitespacesAndNewlines)
                if !fallback.isEmpty {
                    appendAssistant(fallback)
                }
            }
            if let start = turnStartedAt {
                lastTurnDuration = Date().timeIntervalSince(start)
            }
            isBusy = false
            injecting = false
            streamingAssistantId = nil
            streamingThoughtId = nil
            turnStartedAt = nil
            persist(immediate: true)
            requestFocus()
            flushPendingInjection()
        }
    }

    private func announceInterruptedWorkspaceIfNeeded() {
        guard workspaceState.active?.status == .interrupted else { return }
        workspaceState.active = nil
        persistWorkspaceState()
    }

    private func isWorkspaceRunTool(_ update: [String: Any]) -> Bool {
        let title = (update.string("title") ?? "").lowercased()
        let kind = (update.string("kind") ?? "").lowercased()
        if title.contains("workspace_run") || title.contains("workspace run") { return true }
        if kind.contains("workspace") { return true }
        if let raw = JSONValue.object(update["rawInput"]),
           raw.string("mount") != nil,
           raw.string("prompt") != nil {
            return true
        }
        return false
    }

    private func applyChildUpdateData(_ data: Data, sessionId routedSessionId: String) {
        guard let params = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        let update = params.dictionary("update") ?? params
        let kind = update.string("sessionUpdate") ?? ""
        let path = workspaceState.active?.path
        let runId = workspaceState.active?.runId
        let sessionId = routedSessionId.isEmpty ? childSessionId : routedSessionId
        switch kind {
        case "agent_message_chunk":
            let customStart = JSONValue.bool(update["bubbleCustomMessageStart"]) == true
            let forceNew = customStart || workspacePaneForceNewAssistantRow
            if forceNew && !customStart {
                workspacePaneForceNewAssistantRow = false
            }
            if let content = AssistantMessageContent.parse(update["content"]) {
                switch content {
                case .text(let text):
                    childAssistant += text
                    patchActiveSummary(childAssistant)
                    appendWorkspacePaneAssistant(
                        text,
                        path: path,
                        sessionId: sessionId,
                        runId: runId,
                        forceNew: forceNew
                    )
                case .image(let image):
                    appendWorkspacePaneAssistantImage(
                        image,
                        path: path,
                        sessionId: sessionId,
                        runId: runId,
                        forceNew: forceNew
                    )
                }
            }
            if JSONValue.bool(update["bubbleCustomMessageEnd"]) == true {
                workspacePaneStreamingAssistantId = nil
                workspacePaneForceNewAssistantRow = true
            }
        case "agent_thought_chunk":
            if let text = extractText(update["content"]), !text.isEmpty {
                appendWorkspacePaneThought(text, path: path, sessionId: sessionId, runId: runId)
                appendWorkspaceThought(text)
            }
        case "tool_call", "tool_call_update":
            upsertWorkspacePaneTool(
                update,
                isUpdate: kind == "tool_call_update",
                path: path,
                sessionId: sessionId,
                runId: runId
            )
            upsertWorkspaceChildTool(update, isUpdate: kind == "tool_call_update")
        default:
            break
        }
    }

    private func patchActiveSummary(_ text: String) {
        guard var active = workspaceState.active else { return }
        active.summary = WorkspaceRegistry.clip(text, 240)
        workspaceState.active = active
        upsertWorkspaceCard(active)
    }

    private func followOpenWorkspaceStageIfNeeded(_ brief: WorkspaceBrief) {
        guard SideStagePolicy.shouldFollowNewWorkspaceRun(
            currentMountPath: workspaceStage?.path,
            showingFilePreview: filePreview != nil,
            nextMountPath: brief.path
        ),
        let runId = brief.runId,
        let card = items.last(where: {
            $0.kind == .workspaceRun
                && $0.workspacePath == brief.path
                && $0.workspaceRunId == runId
        }) else { return }
        openWorkspaceStage(from: card)
    }

    private func upsertWorkspaceCard(_ brief: WorkspaceBrief) {
        let status = brief.status.rawValue
        if let index = items.lastIndex(where: { $0.kind == .workspaceRun && $0.workspacePath == brief.path }) {
            let userSpokeAfter = items.suffix(from: index + 1).contains { $0.kind == .user }
            let sameRun = brief.runId?.isEmpty == false
                && items[index].workspaceRunId == brief.runId
            if TranscriptStream.shouldReuseWorkspaceCard(
                existingStatus: items[index].workspaceStatus,
                userSpokeAfter: userSpokeAfter,
                sameRun: sameRun
            ) {
                items[index].text = brief.name
                items[index].workspaceRunId = brief.runId
                items[index].workspaceName = brief.name
                items[index].workspaceStatus = status
                items[index].workspaceGoal = brief.goal
                items[index].workspaceSummary = brief.summary
                items[index].workspaceQuestion = brief.question
                items[index].workspaceChangedPaths = brief.changedPaths
                if items[index].workspaceStartedAt == nil {
                    items[index].workspaceStartedAt = Date().timeIntervalSince1970
                }
                persist()
                return
            }
            if TranscriptStream.shouldReuseWorkspaceCard(
                existingStatus: items[index].workspaceStatus,
                userSpokeAfter: false
            ) {
                let hasSummary = !(items[index].workspaceSummary ?? "")
                    .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                items[index].workspaceStatus = hasSummary ? "done" : "interrupted"
            }
        }
        items.append(
            ChatItem(
                kind: .workspaceRun,
                text: brief.name,
                workspacePath: brief.path,
                workspaceRunId: brief.runId,
                workspaceName: brief.name,
                workspaceStatus: status,
                workspaceGoal: brief.goal,
                workspaceSummary: brief.summary,
                workspaceQuestion: brief.question,
                workspaceChangedPaths: brief.changedPaths,
                workspaceChildren: [],
                workspaceStartedAt: Date().timeIntervalSince1970,
                workspaceSessionId: WorkspaceRegistry.sessionId(
                    forMountPath: brief.path,
                    in: workspaceState
                )
            )
        )
        persist()
    }

    private func appendWorkspaceThought(_ raw: String) {
        guard let index = items.lastIndex(where: { $0.kind == .workspaceRun }) else { return }
        var children = items[index].workspaceChildren ?? []
        if TranscriptStream.shouldMergeThought(previousKind: children.last?.kind.rawValue),
           let last = children.indices.last {
            children[last].text = Self.stripDiagnostics(children[last].text + raw)
        } else {
            let cleaned = Self.stripDiagnostics(raw)
            guard !cleaned.isEmpty else { return }
            children.append(ChatItem(kind: .thought, text: cleaned))
        }
        items[index].workspaceChildren = TranscriptStream.cappedChildren(children)
        persist()
    }

    private func upsertWorkspaceChildTool(_ update: [String: Any], isUpdate: Bool) {
        let callId = update.string("toolCallId") ?? UUID().uuidString
        let title = update.string("title") ?? update.string("kind") ?? "tool"
        let status = update.string("status") ?? "pending"
        let payload = extractToolPayload(update)
        let imageNames = persistedImageNames(payload.images)
        if let pathHint = FileChangeSummaryPolicy.pathHint(
            kind: update.string("kind"),
            title: title,
            input: payload.input,
            output: payload.output,
            workspaceRoot: workspaceState.active?.path ?? items.last(where: { $0.kind == .workspaceRun })?.workspacePath
        ) {
            childChanged.append(pathHint)
        }
        guard let index = items.lastIndex(where: { $0.kind == .workspaceRun }) else { return }
        var children = items[index].workspaceChildren ?? []
        if let childIndex = children.lastIndex(where: { $0.kind == .tool && $0.toolId == callId }) {
            children[childIndex].text = title
            children[childIndex].toolStatus = status
            if let input = payload.input { children[childIndex].toolInput = input }
            if let output = payload.output { children[childIndex].toolOutput = output }
            mergeImageNames(imageNames, into: &children[childIndex])
        } else if !isUpdate || title != "tool" {
            children.append(
                ChatItem(
                    kind: .tool,
                    text: title,
                    toolId: callId,
                    toolStatus: status,
                    toolInput: payload.input,
                    toolOutput: payload.output,
                    imageNames: imageNames
                )
            )
        }
        items[index].workspaceChildren = TranscriptStream.cappedChildren(children)
        if var active = workspaceState.active {
            active.summary = title
            workspaceState.active = active
        }
        persist()
    }

}
