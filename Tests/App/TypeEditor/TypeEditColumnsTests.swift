import XCTest

@testable import kmap

/// The colour slots narrow before the field names do, so a hex value stays whole where a
/// row has room for it. `async` for Linux's generated test list, as the screen is
/// main-actor.
@MainActor
final class TypeEditColumnsTests: XCTestCase {
    func testTheSlotsNarrowFirstAndTheRowFits() async {
        XCTAssertTrue(TypeEditScreen.columns(109) == (label: 23, half: 18))
        for width in 52...109 {
            let columns = TypeEditScreen.columns(width)
            XCTAssertEqual(columns.label, 23, "\(width)")
            XCTAssertGreaterThanOrEqual(columns.half, 13, "\(width)")
            XCTAssertLessThanOrEqual(2 + columns.label + 2 * columns.half + 1, width, "\(width)")
        }
        let narrow = TypeEditScreen.columns(40)
        XCTAssertEqual(narrow.half, 13)
        XCTAssertLessThan(narrow.label, 23)
        XCTAssertLessThanOrEqual(2 + narrow.label + 2 * narrow.half + 1, 40)
    }
}
