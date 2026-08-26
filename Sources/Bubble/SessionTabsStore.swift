import BubbleSessions
import Foundation
import Observation

@Observable
final class SessionTabsStore {
    private(set) var state: SessionTabsState
    private var runtimes: [UUID: ChatStore]

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
        guard id != state.selectedID, let next = runtimes[id] else { return }
        let previous = activeStore
        do {
            try state.select(id)
        } catch {
            return
        }
        previous.setStreamUISuspended(true)
        onSelectionChanged?(previous, next)
        next.requestFocus()
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
