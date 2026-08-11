import XCTest
@testable import KeepItCleanTUI

final class TUIRendererSnapshotTests: XCTestCase {
    private let renderer = TUIRenderer(usesANSI: false)

    func testCategorySnapshot() {
        let output = renderer.render(TUIFixture.state())

        XCTAssertEqual(
            output,
            """
            KeepItClean  REVIEW PLAN  | selected reclaim estimate: 1.5 GiB
            ------------------------------------------------------------------------------------------------------------------------
            Categories — Enter drills down; Space changes only the review selection.

            > [x] Gradle  reclaim 2.0 GiB  allocated 2.5 GiB  logical 3.5 GiB
                  2 items | risk review | rebuild mixed | active yes | Versioned generated caches
              [-] Kotlin/Native  reclaim 4.0 GiB  allocated 4.0 GiB  logical 4.0 GiB
                  1 items | risk stateful | rebuild redownload | active unknown | Toolchains need project reference checks

            Up/Down navigate  Enter open  Space select  d detail  c continue  ? help  q quit
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
            KeepItClean  REVIEW PLAN  | selected reclaim estimate: 1.5 GiB
            ------------------------------------------------------------------------------------------------------------------------
            Categories / Gradle — Enter opens details; Space checks an eligible item.

              [x] Artifact cache  reclaim 1.5 GiB  allocated 2.0 GiB  logical 3.0 GiB
                  risk safe | rebuild automatic | confidence high | active no | /Users/test/.gradle/caches/8.9
            > [-] Active daemon state  reclaim 512.0 MiB  allocated 512.0 MiB  logical 512.0 MiB
                  risk review | rebuild manual | confidence high | active yes | /Users/test/.gradle/daemon/8.9

            Up/Down navigate  Enter open  Space select  d detail  c continue  ? help  q quit
            """ + "\n"
        )
    }

    func testDetailSnapshotContainsAllSafetyLabels() {
        var state = TUIFixture.state()
        state.screen = .detail(categoryID: "gradle", itemID: "gradle-cache")

        let output = renderer.render(state)
        XCTAssertTrue(output.contains("Allocated: 2.0 GiB"))
        XCTAssertTrue(output.contains("Logical:   3.0 GiB"))
        XCTAssertTrue(output.contains("Reclaim:   1.5 GiB (estimate)"))
        XCTAssertTrue(output.contains("Risk:      safe"))
        XCTAssertTrue(output.contains("Rebuild:   automatic"))
        XCTAssertTrue(output.contains("Confidence: high"))
        XCTAssertTrue(output.contains("Active:    no"))
        XCTAssertTrue(output.contains("Age:       unknown"))
        XCTAssertTrue(output.contains("Selectable: yes"))
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
