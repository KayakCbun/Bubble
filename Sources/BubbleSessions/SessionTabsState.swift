import Foundation
import CoreGraphics

public enum SessionTabsError: Error, Equatable, Sendable {
    case duplicateSession
    case limitReached(maximum: Int)
    case unknownSession
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

public struct SessionTabsState: Equatable, Sendable {
    public static let defaultMaximum = 5

    public private(set) var tabs: [SessionTabState]
    public private(set) var selectedID: UUID
    public let maximum: Int

    public init(
        primaryID: UUID,
        maximum: Int = SessionTabsState.defaultMaximum
    ) {
        precondition(maximum > 0)
        self.maximum = maximum
        tabs = [SessionTabState(id: primaryID, ordinal: 1)]
        selectedID = primaryID
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
        return id
    }

    public mutating func select(_ id: UUID) throws {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else {
            throw SessionTabsError.unknownSession
        }
        selectedID = id
        tabs[index].hasUnread = false
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
        collapsedWidth: 14,
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
}
