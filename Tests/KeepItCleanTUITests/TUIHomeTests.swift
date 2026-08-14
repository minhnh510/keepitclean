import XCTest
@testable import KeepItCleanTUI

final class TUIHomeTests: XCTestCase {
    func testHomeRendererHasDistinctBrandMenuAndSafetyContract() {
        let output = TUIHomeRenderer(usesANSI: false).render(
            TUIHomeState(width: 120, height: 32)
        )

        XCTAssertTrue(output.contains("_  __ _____ _____ ____"))
        XCTAssertTrue(output.contains("IT CLEAN"))
        XCTAssertTrue(output.contains("Developer storage, under control."))
        XCTAssertTrue(output.contains("› 1. Clean"))
        XCTAssertTrue(output.contains("Developer + hardcore + system cleanup in one review"))
        XCTAssertTrue(output.contains("[ALL-IN-ONE]"))
        XCTAssertTrue(output.contains("2. Analyze"))
        XCTAssertTrue(output.contains("3. Doctor"))
        XCTAssertTrue(output.contains("4. History"))
        XCTAssertFalse(output.contains("2. Hardcore"))
        XCTAssertFalse(output.contains("System Clean"))
        XCTAssertTrue(output.contains("SAFETY  Trash-first · No data collection · Undo available"))
        XCTAssertTrue(output.contains("Clean requests admin access only when the optional system helper is ready."))
        XCTAssertTrue(output.contains("1–4 quick select"))
        XCTAssertTrue(output.contains("? safety details"))
    }

    func testHomeNavigationWrapsAndEnterChoosesFocusedAction() {
        var state = TUIHomeState()
        state = TUIHomeReducer.reduce(state, action: .moveUp).state
        XCTAssertEqual(state.cursor, 3)

        let transition = TUIHomeReducer.reduce(state, action: .open)
        XCTAssertEqual(transition.effect, .choose(.history))
    }

    func testHomeNumberKeyChoosesMatchingAction() {
        let transition = TUIHomeReducer.reduce(
            TUIHomeState(),
            action: .selectIndex(0)
        )
        XCTAssertEqual(transition.state.cursor, 0)
        XCTAssertEqual(transition.effect, .choose(.clean))
    }

    func testQuestionMarkShowsSafetyDetailsAndEscapeReturnsHome() {
        var state = TUIHomeState()
        var transition = TUIHomeReducer.reduce(state, action: .toggleHelp)
        state = transition.state
        XCTAssertTrue(state.showsSafetyHelp)

        let output = TUIHomeRenderer(usesANSI: false).render(state)
        XCTAssertTrue(output.contains("SAFETY DETAILS"))
        XCTAssertTrue(output.contains("Normal cleanup moves verified items to macOS Trash."))
        XCTAssertTrue(output.contains("No telemetry, analytics, cloud upload, account, or background daemon."))
        XCTAssertTrue(output.contains("Use keep undo <ID> or keep system undo <ID>"))
        XCTAssertTrue(output.contains("finalize is permanent and cannot be undone"))

        transition = TUIHomeReducer.reduce(state, action: .back)
        XCTAssertFalse(transition.state.showsSafetyHelp)
        XCTAssertEqual(transition.effect, .none)
    }

    func testPlainHomeRendererRespectsNarrowTerminalWidth() {
        let state = TUIHomeState(width: 60, height: 20)
        let output = TUIHomeRenderer(usesANSI: false).render(state)
        for line in output.split(separator: "\n", omittingEmptySubsequences: false) {
            XCTAssertLessThanOrEqual(line.count, 60, "line exceeded width: \(line)")
        }
    }
}
