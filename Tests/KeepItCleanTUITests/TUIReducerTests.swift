import XCTest
@testable import KeepItCleanTUI

final class TUIReducerTests: XCTestCase {
    func testInitialSelectionIncludesOnlyEligibleDefaults() {
        let state = TUIFixture.state()

        XCTAssertEqual(state.selectedItemIDs, ["gradle-cache"])
        XCTAssertEqual(state.checkmark(for: state.categories[0]), .on)
        XCTAssertEqual(state.checkmark(for: state.categories[1]), .unavailable)
    }

    func testCategoryToggleSelectsAndDeselectsOnlyEligibleItems() {
        var state = TUIFixture.state()

        state = TUIReducer.reduce(state, action: .toggleSelection).state
        XCTAssertTrue(state.selectedItemIDs.isEmpty)

        state = TUIReducer.reduce(state, action: .toggleSelection).state
        XCTAssertEqual(state.selectedItemIDs, ["gradle-cache"])
        XCTAssertFalse(state.selectedItemIDs.contains("gradle-active"))
    }

    func testDrilldownDetailAndBackPreserveCursorAndSelection() {
        var state = TUIFixture.state()
        state = TUIReducer.reduce(state, action: .open).state
        XCTAssertEqual(state.screen, .items(categoryID: "gradle"))

        state = TUIReducer.reduce(state, action: .moveDown).state
        state = TUIReducer.reduce(state, action: .open).state
        XCTAssertEqual(state.screen, .detail(categoryID: "gradle", itemID: "gradle-active"))

        state = TUIReducer.reduce(state, action: .back).state
        XCTAssertEqual(state.screen, .items(categoryID: "gradle"))
        XCTAssertEqual(state.itemCursors["gradle"], 1)
        XCTAssertEqual(state.selectedItemIDs, ["gradle-cache"])
    }

    func testBlockedActiveItemCannotBeSelected() {
        var state = TUIFixture.state()
        state = TUIReducer.reduce(state, action: .open).state
        state = TUIReducer.reduce(state, action: .moveDown).state
        state = TUIReducer.reduce(state, action: .toggleSelection).state

        XCTAssertFalse(state.selectedItemIDs.contains("gradle-active"))
        XCTAssertEqual(state.notice, "Active developer state is never selected.")
    }

    func testConfirmReturnsSortedReviewedIDsWithoutMutatingState() {
        let state = TUIFixture.state()
        let transition = TUIReducer.reduce(state, action: .confirmSelection)

        XCTAssertEqual(transition.state, state)
        XCTAssertEqual(transition.effect, .acceptSelection(itemIDs: ["gradle-cache"]))
    }

    func testApplyRequiresFinalReviewMode() {
        let transition = TUIReducer.reduce(TUIFixture.state(), action: .requestApply)

        XCTAssertEqual(transition.effect, .none)
        XCTAssertEqual(transition.state.screen, .categories)
        XCTAssertEqual(transition.state.notice, "Finish the deep scan before applying cleanup.")
    }

    func testApplyUsesSeparateConfirmationScreenAndEnterEffect() {
        var transition = TUIReducer.reduce(
            TUIFixture.state(allowsApply: true),
            action: .requestApply
        )
        XCTAssertEqual(transition.effect, .none)
        XCTAssertEqual(transition.state.screen, .confirmApply(returnTo: .categories))

        transition = TUIReducer.reduce(transition.state, action: .open)
        XCTAssertEqual(transition.effect, .applySelection(itemIDs: ["gradle-cache"]))
    }

    func testApplyConfirmationCanBeCancelledWithoutEffect() {
        var state = TUIReducer.reduce(
            TUIFixture.state(allowsApply: true),
            action: .requestApply
        ).state
        state = TUIReducer.reduce(state, action: .back).state
        XCTAssertEqual(state.screen, .categories)
        XCTAssertEqual(state.selectedItemIDs, ["gradle-cache"])
    }

    func testAutomaticReviewDoesNotAllowSelectionDrift() {
        let category = TUIFixture.state().categories[0]
        var state = TUIState(
            categories: [category],
            allowsApply: true,
            usesAutomaticSelection: true
        )
        let original = state.selectedItemIDs

        state = TUIReducer.reduce(state, action: .toggleSelection).state
        XCTAssertEqual(state.selectedItemIDs, original)
        XCTAssertEqual(
            state.notice,
            "Eligible items are selected automatically; blocked items stay protected."
        )
    }

    func testBackFromCategoriesQuits() {
        let transition = TUIReducer.reduce(TUIFixture.state(), action: .back)
        XCTAssertEqual(transition.effect, .quit)
    }

    func testHelpReturnsToPriorDetail() {
        var state = TUIFixture.state()
        state.screen = .detail(categoryID: "gradle", itemID: "gradle-cache")
        state = TUIReducer.reduce(state, action: .toggleHelp).state
        XCTAssertEqual(
            state.screen,
            .help(returnTo: .detail(categoryID: "gradle", itemID: "gradle-cache"))
        )
        state = TUIReducer.reduce(state, action: .toggleHelp).state
        XCTAssertEqual(state.screen, .detail(categoryID: "gradle", itemID: "gradle-cache"))
    }

    func testResizeEnforcesUsableMinimum() {
        let state = TUIReducer.reduce(
            TUIFixture.state(),
            action: .resize(width: 1, height: 1)
        ).state
        XCTAssertEqual(state.width, 60)
        XCTAssertEqual(state.height, 16)
    }
}
