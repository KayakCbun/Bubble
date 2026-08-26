import Foundation
import CoreGraphics

public enum SessionTabsError: Error, Equatable, Sendable {
    case duplicateSession
    case limitReached(maximum: Int)
    case unknownSession
}

public enum SessionTabRuntimeRole: String, Codable, Equatable, Sendable {
    case main
    case side
}

public struct PersistedSessionTab: Codable, Equatable, Sendable {
    public var runtimeID: UUID
    public var sessionID: String
    public var role: SessionTabRuntimeRole

    public init(runtimeID: UUID, sessionID: String, role: SessionTabRuntimeRole) {
        self.runtimeID = runtimeID
        self.sessionID = sessionID
        self.role = role
    }
}

public struct SessionTabsSnapshot: Codable, Equatable, Sendable {
    public var entries: [PersistedSessionTab]
    public var selectedRuntimeID: UUID

    public init(entries: [PersistedSessionTab], selectedRuntimeID: UUID) {
        self.entries = entries
        self.selectedRuntimeID = selectedRuntimeID
    }
}

public enum SessionTabsPersistence {
    public static func save(_ snapshot: SessionTabsSnapshot, to url: URL) throws {
        let data = try JSONEncoder().encode(snapshot)
        try data.write(to: url, options: .atomic)
    }

    public static func load(from url: URL) -> SessionTabsSnapshot? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(SessionTabsSnapshot.self, from: data)
    }
}

public enum ResumeDestinationPolicy {
    public static func requiresChoice(sessionID: String, currentSessionID: String?) -> Bool {
        !sessionID.isEmpty && sessionID != currentSessionID
    }
}

public struct ResumeDestinationPrompt: Equatable, Sendable {
    public let sessionID: String

    public init(sessionID: String) {
        self.sessionID = sessionID
    }
}

public enum ResumeDestinationChoice: Equatable, Sendable {
    case side
    case replaceCurrent
    case cancel
}

public enum ResumeDestinationResolution: Equatable, Sendable {
    case side(sessionID: String)
    case replaceCurrent(sessionID: String)
    case cancelled
}

public enum ResumeDestinationSelectionOutcome: Equatable, Sendable {
    case actionQueued
    case cancelled
}

public struct ResumeDestinationState: Equatable, Sendable {
    public private(set) var prompt: ResumeDestinationPrompt?
    public private(set) var pendingAction: ResumeDestinationResolution?

    public init() {}

    public mutating func request(sessionID: String) {
        pendingAction = nil
        prompt = ResumeDestinationPrompt(sessionID: sessionID)
    }

    public var isPerformingAction: Bool {
        pendingAction != nil
    }

    public mutating func choose(_ choice: ResumeDestinationChoice) -> ResumeDestinationSelectionOutcome? {
        guard let prompt else { return nil }
        self.prompt = nil
        switch choice {
        case .side:
            pendingAction = .side(sessionID: prompt.sessionID)
            return .actionQueued
        case .replaceCurrent:
            pendingAction = .replaceCurrent(sessionID: prompt.sessionID)
            return .actionQueued
        case .cancel:
            pendingAction = nil
            return .cancelled
        }
    }

    public mutating func takePendingAction() -> ResumeDestinationResolution? {
        defer { pendingAction = nil }
        return pendingAction
    }
}

public enum SessionTabPreviewPolicy {
    public static func summary(
        from firstUserInput: String?,
        maxCharacters: Int = 72
    ) -> String {
        guard maxCharacters > 1 else { return "" }
        let compact = firstUserInput?
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ") ?? ""
        guard !compact.isEmpty else { return "New session" }
        guard compact.count > maxCharacters else { return compact }
        let end = compact.index(compact.startIndex, offsetBy: maxCharacters - 1)
        return String(compact[..<end]).trimmingCharacters(in: .whitespaces) + "…"
    }
}

public struct SessionTabState: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let ordinal: Int
    public var isBusy: Bool
    public var hasUnread: Bool

    public init(
        id: UUID,
        ordinal: Int,
        isBusy: Bool = false,
        hasUnread: Bool = false
    ) {
        self.id = id
        self.ordinal = ordinal
        self.isBusy = isBusy
        self.hasUnread = hasUnread
    }
}

public enum SessionSelectionPhase: Equatable, Sendable {
    case idle
    case requested(UUID)
    case rendering(UUID)
}

public enum SessionSelectionRequestPolicy {
    public static func shouldForward(
        requestedID: UUID,
        activeID: UUID,
        phase: SessionSelectionPhase
    ) -> Bool {
        requestedID != activeID || phase != .idle
    }
}

public struct SessionTabsState: Equatable, Sendable {
    public static let defaultMaximum = 5

    public private(set) var tabs: [SessionTabState]
    public private(set) var selectedID: UUID
    public private(set) var selectionPhase: SessionSelectionPhase
    public let maximum: Int

    public init(
        primaryID: UUID,
        maximum: Int = SessionTabsState.defaultMaximum
    ) {
        precondition(maximum > 0)
        self.maximum = maximum
        tabs = [SessionTabState(id: primaryID, ordinal: 1)]
        selectedID = primaryID
        selectionPhase = .idle
    }

    public init(
        snapshot: SessionTabsSnapshot,
        maximum: Int = SessionTabsState.defaultMaximum
    ) throws {
        guard maximum > 0,
              !snapshot.entries.isEmpty,
              snapshot.entries.count <= maximum,
              snapshot.entries.first?.role == .main,
              snapshot.entries.dropFirst().allSatisfy({ $0.role == .side }),
              Set(snapshot.entries.map(\.runtimeID)).count == snapshot.entries.count,
              snapshot.entries.contains(where: { $0.runtimeID == snapshot.selectedRuntimeID }) else {
            throw SessionTabsError.unknownSession
        }
        self.maximum = maximum
        tabs = snapshot.entries.enumerated().map { index, entry in
            SessionTabState(id: entry.runtimeID, ordinal: index + 1)
        }
        selectedID = snapshot.selectedRuntimeID
        selectionPhase = .idle
    }

    public var showsTabs: Bool {
        tabs.count > 1
    }

    @discardableResult
    public mutating func createSideSession(id: UUID) throws -> UUID {
        guard !tabs.contains(where: { $0.id == id }) else {
            throw SessionTabsError.duplicateSession
        }
        guard tabs.count < maximum else {
            throw SessionTabsError.limitReached(maximum: maximum)
        }
        tabs.append(SessionTabState(id: id, ordinal: tabs.count + 1))
        selectedID = id
        selectionPhase = .idle
        return id
    }

    public var presentedSelectedID: UUID {
        switch selectionPhase {
        case .requested(let id), .rendering(let id): id
        case .idle: selectedID
        }
    }

    public var isSwitching: Bool {
        selectionPhase != .idle
    }

    public mutating func requestSelection(_ id: UUID) throws {
        guard tabs.contains(where: { $0.id == id }) else {
            throw SessionTabsError.unknownSession
        }
        guard id != selectedID else {
            if case .rendering(let renderingID) = selectionPhase,
               renderingID == id {
                return
            }
            selectionPhase = .idle
            return
        }
        selectionPhase = .requested(id)
    }

    @discardableResult
    public mutating func commitRequestedSelection() -> UUID? {
        guard case .requested(let id) = selectionPhase,
              let index = tabs.firstIndex(where: { $0.id == id }) else {
            return nil
        }
        selectedID = id
        tabs[index].hasUnread = false
        selectionPhase = .rendering(id)
        return id
    }

    public mutating func finishSelection(_ id: UUID) {
        guard case .rendering(let renderingID) = selectionPhase,
              renderingID == id,
              selectedID == id else { return }
        selectionPhase = .idle
    }

    public mutating func setBusy(_ busy: Bool, for id: UUID) throws {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else {
            throw SessionTabsError.unknownSession
        }
        tabs[index].isBusy = busy
    }

    public mutating func markUpdated(_ id: UUID) throws {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else {
            throw SessionTabsError.unknownSession
        }
        if id != selectedID {
            tabs[index].hasUnread = true
        }
    }
}

public struct SessionTabLayoutMetrics: Equatable, Sendable {
    public var collapsedWidth: CGFloat
    public var expandedWidth: CGFloat
    public var height: CGFloat
    public var spacing: CGFloat
    public var topOffset: CGFloat
    public var cornerRadius: CGFloat

    public init(
        collapsedWidth: CGFloat,
        expandedWidth: CGFloat,
        height: CGFloat,
        spacing: CGFloat,
        topOffset: CGFloat,
        cornerRadius: CGFloat
    ) {
        self.collapsedWidth = collapsedWidth
        self.expandedWidth = expandedWidth
        self.height = height
        self.spacing = spacing
        self.topOffset = topOffset
        self.cornerRadius = cornerRadius
    }

    public static let bubble = SessionTabLayoutMetrics(
        collapsedWidth: 20,
        expandedWidth: 32,
        height: 32,
        spacing: 8,
        topOffset: 24,
        cornerRadius: 8
    )
}

public enum SessionTabLayout {
    public static func hitRegions(
        count: Int,
        transcriptOriginY: CGFloat,
        trailingX: CGFloat,
        metrics: SessionTabLayoutMetrics = .bubble
    ) -> [CGRect] {
        guard count > 0 else { return [] }
        let x = trailingX - metrics.expandedWidth
        let stride = metrics.height + metrics.spacing
        var regions: [CGRect] = []
        regions.reserveCapacity(count)
        for index in 0..<count {
            let y = transcriptOriginY + metrics.topOffset + CGFloat(index) * stride
            regions.append(CGRect(
                x: x,
                y: y,
                width: metrics.expandedWidth,
                height: metrics.height
            ))
        }
        return regions
    }

    public static func index(
        at point: CGPoint,
        count: Int,
        transcriptOriginY: CGFloat,
        trailingX: CGFloat,
        metrics: SessionTabLayoutMetrics = .bubble
    ) -> Int? {
        hitRegions(
            count: count,
            transcriptOriginY: transcriptOriginY,
            trailingX: trailingX,
            metrics: metrics
        ).firstIndex(where: { $0.contains(point) })
    }
}
