import Foundation

public enum TUIRisk: String, Codable, CaseIterable, Sendable {
    case safe
    case review
    case stateful
    case blocked

    public var label: String { rawValue }

    var rank: Int {
        switch self {
        case .safe: 0
        case .review: 1
        case .stateful: 2
        case .blocked: 3
        }
    }
}

public enum TUIRebuild: String, Codable, CaseIterable, Sendable {
    case automatic
    case redownload
    case manual
    case none
    case unknown

    public var label: String { rawValue }
}

public enum TUIActivity: String, Codable, CaseIterable, Sendable {
    case inactive = "no"
    case active = "yes"
    case unknown

    public var label: String { rawValue }
}

public struct TUIItem: Identifiable, Equatable, Codable, Sendable {
    public let id: String
    public let title: String
    public let path: String
    public let allocatedBytes: UInt64
    public let logicalBytes: UInt64
    public let reclaimableBytes: UInt64
    public let risk: TUIRisk
    public let rebuild: TUIRebuild
    public let confidence: String
    public let activity: TUIActivity
    public let age: String
    public let reason: String
    public let isSelectable: Bool
    public let isInitiallySelected: Bool

    public init(
        id: String,
        title: String,
        path: String,
        allocatedBytes: UInt64,
        logicalBytes: UInt64,
        reclaimableBytes: UInt64,
        risk: TUIRisk,
        rebuild: TUIRebuild,
        confidence: String = "high",
        activity: TUIActivity,
        reason: String,
        isSelectable: Bool,
        isInitiallySelected: Bool = false,
        age: String = "unknown"
    ) {
        self.id = id
        self.title = title
        self.path = path
        self.allocatedBytes = allocatedBytes
        self.logicalBytes = logicalBytes
        self.reclaimableBytes = reclaimableBytes
        self.risk = risk
        self.rebuild = rebuild
        self.confidence = confidence
        self.activity = activity
        self.age = age
        self.reason = reason
        self.isSelectable = isSelectable
        self.isInitiallySelected = isInitiallySelected && isSelectable
    }
}

public struct TUICategory: Identifiable, Equatable, Codable, Sendable {
    public let id: String
    public let title: String
    public let summary: String
    public var items: [TUIItem]

    public init(id: String, title: String, summary: String, items: [TUIItem]) {
        self.id = id
        self.title = title
        self.summary = summary
        self.items = items
    }

    public var allocatedBytes: UInt64 {
        items.reduce(0) { $0.addingClamped($1.allocatedBytes) }
    }

    public var logicalBytes: UInt64 {
        items.reduce(0) { $0.addingClamped($1.logicalBytes) }
    }

    public var reclaimableBytes: UInt64 {
        items.reduce(0) { $0.addingClamped($1.reclaimableBytes) }
    }

    public var highestRisk: TUIRisk {
        items.map(\.risk).max(by: { $0.rank < $1.rank }) ?? .blocked
    }

    public var rebuildLabel: String {
        let labels = Set(items.map(\.rebuild.label))
        return labels.count == 1 ? (labels.first ?? TUIRebuild.unknown.label) : "mixed"
    }

    public var activityLabel: String {
        if items.contains(where: { $0.activity == .active }) { return TUIActivity.active.label }
        if items.contains(where: { $0.activity == .unknown }) { return TUIActivity.unknown.label }
        return TUIActivity.inactive.label
    }
}

public enum TUICheckmark: Equatable, Sendable {
    case off
    case on
    case mixed
    case unavailable

    public var glyph: String {
        switch self {
        case .off: " "
        case .on: "x"
        case .mixed: "~"
        case .unavailable: "-"
        }
    }
}

public enum TUIScreen: Equatable, Sendable {
    case categories
    case items(categoryID: String)
    case detail(categoryID: String, itemID: String)
    case help(returnTo: TUIScreenReturnPoint)
}

public enum TUIScreenReturnPoint: Equatable, Sendable {
    case categories
    case items(categoryID: String)
    case detail(categoryID: String, itemID: String)
}

public struct TUIState: Equatable, Sendable {
    public var categories: [TUICategory]
    public var screen: TUIScreen
    public var categoryCursor: Int
    public var itemCursors: [String: Int]
    public var selectedItemIDs: Set<String>
    public var width: Int
    public var height: Int
    public var notice: String?

    public init(
        categories: [TUICategory],
        screen: TUIScreen = .categories,
        width: Int = 100,
        height: Int = 30
    ) {
        self.categories = categories
        self.screen = screen
        self.categoryCursor = 0
        self.itemCursors = [:]
        self.selectedItemIDs = Set(
            categories.flatMap(\.items)
                .filter { $0.isSelectable && $0.isInitiallySelected }
                .map(\.id)
        )
        self.width = max(60, width)
        self.height = max(16, height)
        self.notice = nil
    }

    public var selectedItems: [TUIItem] {
        categories.flatMap(\.items).filter { selectedItemIDs.contains($0.id) }
    }

    public var selectedReclaimableBytes: UInt64 {
        selectedItems.reduce(0) { $0.addingClamped($1.reclaimableBytes) }
    }

    public func category(withID id: String) -> TUICategory? {
        categories.first { $0.id == id }
    }

    public func item(categoryID: String, itemID: String) -> TUIItem? {
        category(withID: categoryID)?.items.first { $0.id == itemID }
    }

    public func checkmark(for category: TUICategory) -> TUICheckmark {
        let selectable = category.items.filter(\.isSelectable)
        guard !selectable.isEmpty else { return .unavailable }
        let selectedCount = selectable.filter { selectedItemIDs.contains($0.id) }.count
        if selectedCount == 0 { return .off }
        if selectedCount == selectable.count { return .on }
        return .mixed
    }
}

extension UInt64 {
    fileprivate func addingClamped(_ other: UInt64) -> UInt64 {
        let (sum, overflow) = addingReportingOverflow(other)
        return overflow ? .max : sum
    }
}
