import XCTest
@testable import KeepItCleanTUI

final class TUIInputDecoderTests: XCTestCase {
    func testSplitArrowSequenceWaitsForCompletion() {
        var decoder = TUIInputDecoder()

        XCTAssertEqual(decoder.feed([0x1B]), [])
        XCTAssertEqual(decoder.feed([0x5B]), [])
        XCTAssertEqual(decoder.feed([0x41]), [.moveUp])
    }

    func testBareEscapeFlushesAsBack() {
        var decoder = TUIInputDecoder()
        XCTAssertEqual(decoder.feed([0x1B]), [])
        XCTAssertEqual(decoder.flush(), [.back])
    }

    func testSafetyRelevantKeys() {
        var decoder = TUIInputDecoder()
        XCTAssertEqual(
            decoder.feed(Array(" c?dq".utf8)),
            [.toggleSelection, .confirmSelection, .toggleHelp, .showDetail, .quit]
        )
        XCTAssertEqual(decoder.feed([0x03]), [.quit])
    }
}
