import XCTest
@testable import KeepItCleanTUI

final class TUIRendererSnapshotTests: XCTestCase {
    private let renderer = TUIRenderer(usesANSI: false)

    func testCategorySnapshot() {
        let output = renderer.render(TUIFixture.state())

        XCTAssertEqual(
            output,
            """
              KEEP IT CLEAN   macOS developer storage   REVIEW ONLY
              Trash-first  •  no sudo  •  no telemetry  •  nothing moves until apply

              1 selected  •  1.5 GiB reclaim  •  1 eligible / 3 found  •  6.0 GiB potential
              ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
            ------------------------------------------------------------------------------------------------------------------------
              REVIEW CATEGORIES
              Choose a category, inspect the evidence, then select only what you want.

              › ●  ◆  Gradle    2.0 GiB reclaim
                    2 items  •  2.5 GiB allocated  •  review  •  ACTIVE
                    Versioned generated caches
                –  K  Kotlin/Native    4.0 GiB reclaim
                    1 item  •  4.0 GiB allocated  •  high risk  •  unknown activity
                    Toolchains need project reference checks

              ↑↓ move   enter open   space select   d details   c review   ? help   q quit
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
              KEEP IT CLEAN   macOS developer storage   REVIEW ONLY
              Trash-first  •  no sudo  •  no telemetry  •  nothing moves until apply

              1 selected  •  1.5 GiB reclaim  •  1 eligible / 3 found  •  6.0 GiB potential
              ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
            ------------------------------------------------------------------------------------------------------------------------
              REVIEW / GRADLE
              Enter details  •  Space select  •  Esc categories

                ●  Artifact cache    1.5 GiB
                    safe  •  rebuild automatic  •  confidence high  •  idle
                    /Users/test/.gradle/caches/8.9
              › –  Active daemon state    512.0 MiB
                    review  •  rebuild manual  •  confidence high  •  ACTIVE
                    /Users/test/.gradle/daemon/8.9

              ↑↓ move   enter open   space select   d details   c review   ? help   q quit
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

    func testNarrowRendererClipsEveryPlainLine() {
        var state = TUIFixture.state()
        state.width = 60
        let output = renderer.render(state)

        for line in output.split(separator: "\n", omittingEmptySubsequences: false) {
            XCTAssertLessThanOrEqual(line.count, 60, "line exceeded width: \(line)")
        }
    }
}
