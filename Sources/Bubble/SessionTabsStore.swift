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
        let id = UUID()
        let primary = ChatStore(runtimeID: id, runtimeRole: .main)
        state = SessionTabsState(primaryID: id)
        runtimes = [id: primary]
        bind(primary, id: id)
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

    func createSideSession() {
        let id = UUID()
        let previous = activeStore
        do {
            try state.createSideSession(id: id)
        } catch SessionTabsError.limitReached(let maximum) {
            activeStore.presentSessionMessage("Bubble supports up to \(maximum) parallel sessions.")
            return
        } catch {
            activeStore.presentSessionMessage("Could not create a side session.")
            return
        }

        let runtime = ChatStore(runtimeID: id, runtimeRole: .side)
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
            if runtime.isConnected, runtime.items.isEmpty {
                runtime.presentSessionMessage("Bubble is ready.")
            }
        }
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
        for runtime in runtimes.values {
            runtime.shutdown()
        }
    }

    private func bind(_ runtime: ChatStore, id: UUID) {
        runtime.onCreateSideSession = { [weak self] in
            self?.createSideSession()
        }
        runtime.onActivityChanged = { [weak self] busy in
            try? self?.state.setBusy(busy, for: id)
        }
        runtime.onTranscriptUpdated = { [weak self] in
            try? self?.state.markUpdated(id)
        }
    }
}
