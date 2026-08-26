import BubbleSessions
import Foundation
import Observation

@Observable
final class SessionTabsStore {
    private(set) var state: SessionTabsState
    private var runtimes: [UUID: ChatStore]
    @ObservationIgnored private var selectionGeneration = 0

    var onSelectionChanged: ((ChatStore, ChatStore) -> Void)?
    var onRuntimeCreated: ((ChatStore) -> Void)?

    init() {
        if let snapshot = Self.loadSessionTabs(),
           let restoredState = try? SessionTabsState(snapshot: snapshot) {
            state = restoredState
            var restored: [UUID: ChatStore] = [:]
            for entry in snapshot.entries {
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
        guard let next = runtimes[id] else { return }
        selectionGeneration &+= 1
        let generation = selectionGeneration
        do {
            try state.requestSelection(id)
        } catch {
            return
        }
        guard case .requested = state.selectionPhase else { return }
        guard usesLoadingMask(for: next) else {
            commitRequestedSelection(waitForLayout: false)
            return
        }
        OverlayPulse.shared.onNextFrame { [weak self] in
            guard let self, self.selectionGeneration == generation else { return }
            OverlayPulse.shared.onNextFrame { [weak self] in
                guard let self, self.selectionGeneration == generation else { return }
                self.commitRequestedSelection(waitForLayout: true)
            }
        }
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
            self?.state.finishSelection(id)
        }
    }

    private func commitRequestedSelection(waitForLayout: Bool) {
        let previous = activeStore
        guard let id = state.commitRequestedSelection(),
              let next = runtimes[id] else { return }
        persistSessionTabs()
        if !waitForLayout {
            state.finishSelection(id)
        }
        previous.setStreamUISuspended(true)
        onSelectionChanged?(previous, next)
        next.requestFocus()
    }

    private func usesLoadingMask(for runtime: ChatStore) -> Bool {
        let visibleItems = runtime.visibleItems
        var textBytes = 0
        var mediaCount = 0
        for item in visibleItems {
            textBytes = min(
                SessionSwitchLoadingPolicy.textByteThreshold,
                textBytes + item.text.utf8.count
            )
            mediaCount += item.imageNames?.count ?? 0
            if SessionSwitchLoadingPolicy.usesMask(
                sourceItemCount: visibleItems.count,
                textBytes: textBytes,
                mediaCount: mediaCount
            ) {
                return true
            }
        }
        return false
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
        runtime.onResumeInSideSession = { [weak self] sessionID in
            self?.createSideSession(resuming: sessionID)
        }
        runtime.onSessionIdentityChanged = { [weak self] in
            self?.persistSessionTabs()
        }
        runtime.onActivityChanged = { [weak self] busy in
            try? self?.state.setBusy(busy, for: id)
        }
        runtime.onTranscriptUpdated = { [weak self] in
            try? self?.state.markUpdated(id)
        }
    }

    private func persistSessionTabs() {
        let entries = state.tabs.compactMap { tab -> PersistedSessionTab? in
            guard let runtime = runtimes[tab.id],
                  let sessionID = runtime.currentSessionID ?? (tab.ordinal == 1 ? PiSessions.currentId() : nil),
                  !sessionID.isEmpty else { return nil }
            return PersistedSessionTab(
                runtimeID: tab.id,
                sessionID: sessionID,
                role: runtime.sessionTabRole
            )
        }
        guard entries.count == state.tabs.count else { return }
        let snapshot = SessionTabsSnapshot(
            entries: entries,
            selectedRuntimeID: state.selectedID
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
