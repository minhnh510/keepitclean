import XCTest
@testable import KeepItCleanTUI

final class TUIRendererSnapshotTests: XCTestCase {
    private let renderer = TUIRenderer(usesANSI: false)

    func testCategorySnapshot() {
        let output = renderer.render(TUIFixture.state())

        XCTAssertEqual(
            output,
            """
              KEEP IT CLEAN  /  macOS developer cleaner
              SAFETY  Trash-first · No data collection · Undo available  SCAN + REVIEW

              1 selected  •  1.5 GiB reclaim  •  1 eligible / 3 found  •  6.0 GiB potential
              ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
            ------------------------------------------------------------------------------------------------------------------------
              CLEANUP CATEGORIES
              Inspect what will move to Trash or protected quarantine.

              › ●  1. Gradle  2.0 GiB  2 items
                   ◆  review  •  ACTIVE
                –  2. Kotlin/Native  4.0 GiB  1 item
                   K  high risk  •  unknown activity

              ↑↓ move   enter open   space select   c deep review   ? help   q quit
            """ + "\n"
        )
    }

    func testItemSnapshot() {
        var state = TUIFixture.state()
        state.screen = .items(categoryID: "gradle")
        state.itemCursors["gradle"] = 1

        XCTAssertEqual(
            renderer.render(state),
            """
              KEEP IT CLEAN  /  macOS developer cleaner
              SAFETY  Trash-first · No data collection · Undo available  SCAN + REVIEW

              1 selected  •  1.5 GiB reclaim  •  1 eligible / 3 found  •  6.0 GiB potential
              ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
            ------------------------------------------------------------------------------------------------------------------------
              REVIEW / GRADLE
              Enter details  •  Space select  •  Esc categories

                ●  Artifact cache    1.5 GiB
                    /Users/test/.gradle/caches/8.9  •  safe  •  rebuild automatic  •  idle
              › –  Active daemon state    512.0 MiB
                    /Users/test/.gradle/daemon/8.9  •  review  •  rebuild manual  •  ACTIVE

              ↑↓ move   enter open   space select   c deep review   ? help   q quit
            """ + "\n"
        )
    }

    func testDetailSnapshotContainsAllSafetyLabels() {
        var state = TUIFixture.state()
        state.screen = .detail(categoryID: "gradle", itemID: "gradle-cache")

        let output = renderer.render(state)
        XCTAssertTrue(output.contains("Allocated   2.0 GiB"))
        XCTAssertTrue(output.contains("Logical     3.0 GiB"))
        XCTAssertTrue(output.contains("Reclaim     1.5 GiB estimate"))
        XCTAssertTrue(output.contains("Risk        safe"))
        XCTAssertTrue(output.contains("Rebuild     automatic"))
        XCTAssertTrue(output.contains("Confidence  high"))
        XCTAssertTrue(output.contains("Activity    idle"))
        XCTAssertTrue(output.contains("Age         unknown"))
        XCTAssertTrue(output.contains("Selectable  yes"))
    }

    func testApplyConfirmationExplainsTrashAndUndo() {
        var state = TUIFixture.state(allowsApply: true)
        state = TUIReducer.reduce(state, action: .requestApply).state

        let output = renderer.render(state)
        XCTAssertTrue(output.contains("CLEAN ALL VERIFIED ITEMS?"))
        XCTAssertTrue(output.contains("keep undo <ID>"))
        XCTAssertTrue(output.contains("Space is reclaimed only after Trash is emptied or quarantine is finalized."))
        XCTAssertTrue(output.contains("enter CLEAN NOW   esc cancel"))
    }

    func testQuestionMarkHelpExplainsSafetyContract() {
        var state = TUIFixture.state()
        state = TUIReducer.reduce(state, action: .toggleHelp).state

        let output = renderer.render(state)
        XCTAssertTrue(output.contains("SAFETY DETAILS"))
        XCTAssertTrue(output.contains("Verified user files move to Trash"))
        XCTAssertTrue(output.contains("No telemetry or uploads"))
        XCTAssertTrue(output.contains("Use keep undo <ID>"))
        XCTAssertTrue(output.contains("finalize cannot be undone"))
    }

    func testNarrowRendererClipsEveryPlainLine() {
        var state = TUIFixture.state()
        state.width = 60
        let output = renderer.render(state)

        for line in output.split(separator: "\n", omittingEmptySubsequences: false) {
            XCTAssertLessThanOrEqual(line.count, 60, "line exceeded width: \(line)")
        }
    }
}
