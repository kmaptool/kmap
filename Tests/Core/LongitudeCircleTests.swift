import XCTest

@testable import kmap

/// The widest gap on the longitude circle.
final class LongitudeCircleTests: XCTestCase {
    func testSpansInOnePieceHaveNoGapInside() {
        XCTAssertNil(LongitudeCircle.gapInside([(32, 34), (34, 36.7), (40, 42)]))
        XCTAssertNil(LongitudeCircle.gapInside([]))
    }

    /// Fiji: tiles on both sides of 180 deg, the planet between them empty.
    func testSpansEitherSideOf180HaveTheGapBetweenThem() throws {
        let gap = try XCTUnwrap(LongitudeCircle.gapInside([(176.2, 180), (172.7, 176.2), (-180, -176.3)]))
        XCTAssertEqual(gap.west, -176.3)
        XCTAssertEqual(gap.east, 172.7)
    }
}
