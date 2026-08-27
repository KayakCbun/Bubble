import BubbleSessions
import Foundation
import Observation

@Observable
final class SessionTabsStore {
    private(set) var state: SessionTabsState
    private var runtimes: [UUID: ChatStore]
    private var tabPreviews: [UUID: String] = [:]
    @ObservationIgnored private var selectionGeneration = 0
    @ObservationIgnored private var sessionSwitchDiagnosticStarted = false
    @ObservationIgnored private var sessionSwitchDiagnosticRequestTime: ContinuousClock.Instant?
    @ObservationIgnored private var sessionSwitchDiagnosticCommitTime: ContinuousClock.Instant?

    var onSelectionChanged: ((ChatStore, ChatStore) -> Void)?
    var onRuntimeCreated: ((ChatStore) -> Void)?

    init() {
        if let snapshot = Self.loadSessionTabs(),
           let restoredState = try? SessionTabsState(snapshot: snapshot) {
            state = restoredState
            var restored: [UUID: ChatStore] = [:]
            let restoreOrder = snapshot.entries.sorted { left, right in
                left.runtimeID == snapshot.selectedRuntimeID
                    && right.runtimeID != snapshot.selectedRuntimeID
            }
            for entry in restoreOrder {
                let role: SessionRuntimeRole = entry.role == .main ? .main : .side
                restored[entry.runtimeID] = ChatStore(
                    runtimeID: entry.runtimeID,
                    runtimeRole: role,
                    initialSessionID: entry.sessionID
                )
            }
            runtimes = restored
        } else {
            let id = UUID()
            let primary = ChatStore(runtimeID: id, runtimeRole: .main)
            state = SessionTabsState(primaryID: id)
            runtimes = [id: primary]
        }
        for tab in state.tabs {
            if let runtime = runtimes[tab.id] {
                bind(runtime, id: tab.id)
                refreshPreview(for: tab.id, runtime: runtime)
            }
        }
    }

    var activeStore: ChatStore {
        guard let store = runtimes[state.selectedID] else {
            preconditionFailure("selected Bubble session runtime is missing")
        }
        return store
    }

    var tabs: [SessionTabState] { state.tabs }
    var showsTabs: Bool { state.showsTabs }
    var presentedSelectedID: UUID { state.presentedSelectedID }
    var isSwitchingSession: Bool { state.isSwitching }
    var allRuntimes: [ChatStore] { state.tabs.compactMap { runtimes[$0.id] } }

    func preview(for id: UUID) -> String {
        tabPreviews[id] ?? SessionTabPreviewPolicy.summary(from: nil)
    }

    @discardableResult
    func createSideSession(resuming sessionID: String? = nil) -> Int? {
        if let sessionID,
           let existing = runtimes.first(where: { $0.value.currentSessionID == sessionID }) {
            select(existing.key)
            return state.tabs.first(where: { $0.id == existing.key })?.ordinal
        }
        let id = UUID()
        let previous = activeStore
        do {
            try state.createSideSession(id: id)
        } catch SessionTabsError.limitReached(let maximum) {
            activeStore.presentSessionMessage("Bubble supports up to \(maximum) parallel sessions.")
            return nil
        } catch {
            activeStore.presentSessionMessage("Could not create a side session.")
            return nil
        }

        let runtime = ChatStore(
            runtimeID: id,
            runtimeRole: .side,
            initialSessionID: sessionID
        )
        runtime.isStartingSession = true
        runtimes[id] = runtime
        bind(runtime, id: id)
        refreshPreview(for: id, runtime: runtime)
        onRuntimeCreated?(runtime)
        previous.setStreamUISuspended(true)
        onSelectionChanged?(previous, runtime)
        runtime.requestFocus()

        Task { @MainActor [weak self, weak runtime] in
            guard let self, let runtime else { return }
            await runtime.connect()
            runtime.isStartingSession = false
            guard self.runtimes[id] === runtime else { return }
            self.persistSessionTabs()
            if runtime.isConnected, runtime.items.isEmpty {
                let message = sessionID.map { "Resumed session \($0)." } ?? "Bubble is ready."
                runtime.presentSessionMessage(message)
            }
        }
        return state.tabs.first(where: { $0.id == id })?.ordinal
    }

    func select(_ id: UUID) {
        guard runtimes[id] != nil else { return }
        guard SessionSelectionRequestPolicy.shouldForward(
            requestedID: id,
            activeID: state.selectedID,
            phase: state.selectionPhase
        ) else { return }
        selectionGeneration &+= 1
        let generation = selectionGeneration
        do {
            try state.requestSelection(id)
        } catch {
            return
        }
        guard case .requested = state.selectionPhase else { return }
        OverlayPulse.shared.onNextFrame { [weak self] in
            guard let self, self.selectionGeneration == generation else { return }
            self.commitRequestedSelection(waitForLayout: true)
        }
    }

    func startSessionSwitchDiagnosticIfNeeded() {
        guard !sessionSwitchDiagnosticStarted,
              ProcessInfo.processInfo.environment["BUBBLE_SESSION_SWITCH_DIAGNOSTICS"] == "1",
              let target = state.tabs.first(where: { $0.id != state.selectedID }) else { return }
        sessionSwitchDiagnosticStarted = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            guard let self else { return }
            self.sessionSwitchDiagnosticRequestTime = .now
            self.select(target.id)
        }
    }

    @discardableResult
    func closeSideSession(_ id: UUID, stopIfBusy: Bool = false) -> Bool {
        guard !state.isSwitching,
              let tab = state.tabs.first(where: { $0.id == id }),
              tab.ordinal != 1,
              let closing = runtimes[id] else { return false }
        guard !closing.isStartingSession else { return false }
        guard !tab.isBusy || stopIfBusy else { return false }

        selectionGeneration &+= 1
        let previous = activeStore
        let result: SessionTabCloseResult
        do {
            result = try state.closeSideSession(id)
        } catch {
            return false
        }
        runtimes.removeValue(forKey: id)
        tabPreviews.removeValue(forKey: id)
        persistSessionTabs()

        if result.selectionChanged {
            let next = activeStore
            previous.setStreamUISuspended(true)
            onSelectionChanged?(previous, next)
            next.requestFocus()
        }
        closing.shutdownClosedTabRuntime()
        return true
    }

    func isAwaitingSelectedLayout(_ id: UUID?) -> Bool {
        guard let id,
              case .rendering(let renderingID) = state.selectionPhase else { return false }
        return renderingID == id
    }

    func selectedLayoutDidApply(_ id: UUID) {
        guard case .rendering(let renderingID) = state.selectionPhase,
              renderingID == id else { return }
        OverlayPulse.shared.onNextFrame { [weak self] in
            self?.selectedContentDidApply(id)
        }
    }

    private func selectedContentDidApply(_ id: UUID) {
        guard case .rendering(let renderingID) = state.selectionPhase,
              renderingID == id else { return }
        state.finishSelection(id)
        finishSessionSwitchDiagnosticIfNeeded()
    }

    private func commitRequestedSelection(waitForLayout: Bool) {
        let previous = activeStore
        guard let id = state.commitRequestedSelection(),
              let next = runtimes[id] else { return }
        if sessionSwitchDiagnosticRequestTime != nil {
            sessionSwitchDiagnosticCommitTime = .now
        }
        persistSessionTabs()
        if !waitForLayout {
            state.finishSelection(id)
        }
        previous.setStreamUISuspended(true)
        onSelectionChanged?(previous, next)
        next.requestFocus()
    }

    private func finishSessionSwitchDiagnosticIfNeeded() {
        guard let request = sessionSwitchDiagnosticRequestTime,
              let commit = sessionSwitchDiagnosticCommitTime else { return }
        let now = ContinuousClock.now
        let requestToCommit = Self.milliseconds(request.duration(to: commit))
        let commitToPresented = Self.milliseconds(commit.duration(to: now))
        OverlayLog.write(String(
            format: "session switch benchmark requestToCommit=%.2fms commitToPresented=%.2fms total=%.2fms",
            requestToCommit,
            commitToPresented,
            requestToCommit + commitToPresented
        ))
        sessionSwitchDiagnosticRequestTime = nil
        sessionSwitchDiagnosticCommitTime = nil
    }

    private static func milliseconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) * 1_000
            + Double(duration.components.attoseconds) / 1_000_000_000_000_000
    }

    func prepareToQuit() {
        persistSessionTabs()
        for runtime in runtimes.values {
            runtime.shutdown()
        }
    }

    private func bind(_ runtime: ChatStore, id: UUID) {
        runtime.onCreateSideSession = { [weak self] in
            self?.createSideSession()
        }
        runtime.onCloseCurrentSession = { [weak self, weak runtime] in
            guard let self, let runtime,
                  !self.state.isSwitching,
                  let tab = self.state.tabs.first(where: { $0.id == id }),
                  tab.ordinal != 1,
                  !runtime.isStartingSession else { return false }
            return self.closeSideSession(id, stopIfBusy: true)
        }
        runtime.onResumeInSideSession = { [weak self] sessionID in
            self?.createSideSession(resuming: sessionID)
        }
        runtime.onSessionIdentityChanged = { [weak self] in
            self?.persistSessionTabs()
            self?.refreshPreview(for: id, runtime: runtime)
        }
        runtime.onActivityChanged = { [weak self] busy in
            try? self?.state.setBusy(busy, for: id)
        }
        runtime.onTranscriptUpdated = { [weak self] in
            try? self?.state.markUpdated(id)
            guard self?.tabPreviews[id] == nil || self?.tabPreviews[id] == "New session" else { return }
            self?.refreshPreview(for: id, runtime: runtime)
        }
    }

    private func refreshPreview(for id: UUID, runtime: ChatStore) {
        let persisted = runtime.currentSessionID.flatMap { sessionID in
            PiSessions.firstUserInput(sessionId: sessionID)
        }
        let local = runtime.items.first(where: { $0.kind == .user })
        tabPreviews[id] = SessionTabPreviewPolicy.summary(
            from: persisted?.text ?? local?.text,
            attachmentCount: persisted?.imageCount ?? local?.imageNames?.count ?? 0
        )
    }

    private func persistSessionTabs() {
        let entries = state.tabs.compactMap { tab -> PersistedSessionTab? in
            guard let runtime = runtimes[tab.id],
                  let sessionID = runtime.currentSessionID ?? (tab.ordinal == 1 ? PiSessions.currentId() : nil),
                  !sessionID.isEmpty else { return nil }
            return PersistedSessionTab(
                runtimeID: tab.id,
                sessionID: sessionID,
                role: runtime.sessionTabRole,
                ordinal: tab.ordinal
            )
        }
        guard !entries.isEmpty else { return }
        let selectedRuntimeID = entries.contains(where: { $0.runtimeID == state.selectedID })
            ? state.selectedID
            : entries[0].runtimeID
        let snapshot = SessionTabsSnapshot(
            entries: entries,
            selectedRuntimeID: selectedRuntimeID
        )
        do {
            try SessionTabsPersistence.save(snapshot, to: OverlayPaths.sessionTabsFile)
        } catch {
            OverlayLog.write("session tabs save failed: \(error.localizedDescription)")
        }
    }

    private static func loadSessionTabs() -> SessionTabsSnapshot? {
        SessionTabsPersistence.load(from: OverlayPaths.sessionTabsFile)
    }
}
