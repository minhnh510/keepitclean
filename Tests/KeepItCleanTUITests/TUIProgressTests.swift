import XCTest
@testable import KeepItCleanTUI

final class TUIProgressTests: XCTestCase {
    func testTrashProgressRunsOperationWhenOutputIsNotATerminal() async throws {
        let value = try await TUITrashProgress.run(
            itemCount: 11,
            reclaimableBytes: 11 * (1 << 30)
        ) {
            "completed"
        }

        XCTAssertEqual(value, "completed")
    }

    func testTrashProgressPropagatesOperationFailure() async {
        struct FixtureError: Error {}

        do {
            _ = try await TUITrashProgress.run(itemCount: 1, reclaimableBytes: 42) {
                throw FixtureError()
            } as String
            XCTFail("Expected the operation error to propagate")
        } catch {
            XCTAssertTrue(error is FixtureError)
        }
    }
}
