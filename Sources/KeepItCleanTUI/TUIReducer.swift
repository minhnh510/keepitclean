import Foundation

public enum TUIAction: Equatable, Sendable {
    case moveUp
    case moveDown
    case open
    case back
    case showDetail
    case toggleSelection
    case toggleHelp
    case confirmSelection
    case quit
    case resize(width: Int, height: Int)
}

public enum TUIEffect: Equatable, Sendable {
    case none
    case acceptSelection(itemIDs: [String])
    case quit
}

public struct TUITransition: Equatable, Sendable {
    public let state: TUIState
    public let effect: TUIEffect

    public init(state: TUIState, effect: TUIEffect = .none) {
        self.state = state
        self.effect = effect
    }
}

public enum TUIReducer {
    public static func reduce(_ state: TUIState, action: TUIAction) -> TUITransition {
        var next = state
        next.notice = nil

        switch action {
        case .moveUp:
            moveCursor(in: &next, delta: -1)
        case .moveDown:
            moveCursor(in: &next, delta: 1)
        case .open:
            open(in: &next)
        case .back:
            if case let .help(returnTo) = next.screen {
                next.screen = returnTo.screen
            } else if !goBack(in: &next) {
                return TUITransition(state: next, effect: .quit)
            }
        case .showDetail:
            showDetail(in: &next)
        case .toggleSelection:
            toggleSelection(in: &next)
        case .toggleHelp:
            toggleHelp(in: &next)
        case .confirmSelection:
            let ids = next.selectedItems.map(\.id).sorted()
            guard !ids.isEmpty else {
                next.notice = "Nothing selectable is checked."
                return TUITransition(state: next)
            }
            return TUITransition(state: next, effect: .acceptSelection(itemIDs: ids))
        case .quit:
            return TUITransition(state: next, effect: .quit)
        case let .resize(width, height):
            next.width = max(60, width)
            next.height = max(16, height)
        }

        return TUITransition(state: next)
    }

    private static func moveCursor(in state: inout TUIState, delta: Int) {
        switch state.screen {
        case .categories:
            guard !state.categories.isEmpty else { return }
            state.categoryCursor = clamped(state.categoryCursor + delta, count: state.categories.count)
        case let .items(categoryID):
            guard let category = state.category(withID: categoryID), !category.items.isEmpty else { return }
            let current = state.itemCursors[categoryID, default: 0]
            state.itemCursors[categoryID] = clamped(current + delta, count: category.items.count)
        case .detail, .help:
            break
        }
    }

    private static func open(in state: inout TUIState) {
        switch state.screen {
        case .categories:
            guard state.categories.indices.contains(state.categoryCursor) else { return }
            let category = state.categories[state.categoryCursor]
            guard !category.items.isEmpty else {
                state.notice = "This category has no candidates."
                return
            }
            state.itemCursors[category.id] = min(
                state.itemCursors[category.id, default: 0],
                max(0, category.items.count - 1)
            )
            state.screen = .items(categoryID: category.id)
        case .items:
            showDetail(in: &state)
        case .detail:
            break
        case let .help(returnTo):
            state.screen = returnTo.screen
        }
    }

    @discardableResult
    private static func goBack(in state: inout TUIState) -> Bool {
        switch state.screen {
        case .categories:
            return false
        case .items:
            state.screen = .categories
        case let .detail(categoryID, _):
            state.screen = .items(categoryID: categoryID)
        case let .help(returnTo):
            state.screen = returnTo.screen
        }
        return true
    }

    private static func showDetail(in state: inout TUIState) {
        guard case let .items(categoryID) = state.screen,
              let category = state.category(withID: categoryID),
              !category.items.isEmpty
        else { return }

        let cursor = clamped(state.itemCursors[categoryID, default: 0], count: category.items.count)
        state.itemCursors[categoryID] = cursor
        state.screen = .detail(categoryID: categoryID, itemID: category.items[cursor].id)
    }

    private static func toggleSelection(in state: inout TUIState) {
        switch state.screen {
        case .categories:
            guard state.categories.indices.contains(state.categoryCursor) else { return }
            let category = state.categories[state.categoryCursor]
            let selectable = category.items.filter(\.isSelectable)
            guard !selectable.isEmpty else {
                state.notice = "This category is blocked by safety policy."
                return
            }
            let allSelected = selectable.allSatisfy { state.selectedItemIDs.contains($0.id) }
            for item in selectable {
                if allSelected {
                    state.selectedItemIDs.remove(item.id)
                } else {
                    state.selectedItemIDs.insert(item.id)
                }
            }
        case let .items(categoryID):
            toggleCurrentItem(categoryID: categoryID, in: &state)
        case let .detail(categoryID, itemID):
            toggleItem(categoryID: categoryID, itemID: itemID, in: &state)
        case .help:
            break
        }
    }

    private static func toggleCurrentItem(categoryID: String, in state: inout TUIState) {
        guard let category = state.category(withID: categoryID), !category.items.isEmpty else { return }
        let cursor = clamped(state.itemCursors[categoryID, default: 0], count: category.items.count)
        toggleItem(categoryID: categoryID, itemID: category.items[cursor].id, in: &state)
    }

    private static func toggleItem(categoryID: String, itemID: String, in state: inout TUIState) {
        guard let item = state.item(categoryID: categoryID, itemID: itemID) else { return }
        guard item.isSelectable else {
            state.notice = item.activity == .active
                ? "Active developer state is never selected."
                : "This candidate is blocked by safety policy."
            return
        }

        if state.selectedItemIDs.contains(item.id) {
            state.selectedItemIDs.remove(item.id)
        } else {
            state.selectedItemIDs.insert(item.id)
        }
    }

    private static func toggleHelp(in state: inout TUIState) {
        if case let .help(returnTo) = state.screen {
            state.screen = returnTo.screen
            return
        }

        let returnTo: TUIScreenReturnPoint
        switch state.screen {
        case .categories:
            returnTo = .categories
        case let .items(categoryID):
            returnTo = .items(categoryID: categoryID)
        case let .detail(categoryID, itemID):
            returnTo = .detail(categoryID: categoryID, itemID: itemID)
        case .help:
            return
        }
        state.screen = .help(returnTo: returnTo)
    }

    private static func clamped(_ value: Int, count: Int) -> Int {
        guard count > 0 else { return 0 }
        return min(max(0, value), count - 1)
    }
}

private extension TUIScreenReturnPoint {
    var screen: TUIScreen {
        switch self {
        case .categories: .categories
        case let .items(categoryID): .items(categoryID: categoryID)
        case let .detail(categoryID, itemID): .detail(categoryID: categoryID, itemID: itemID)
        }
    }
}
