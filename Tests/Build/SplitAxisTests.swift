import XCTest
@testable import kmap

/// Which way a region is cut.
final class SplitAxisTests: RecipeTestCase {

    // MARK: Which way a region is cut

    func testARegionIsCutAcrossItsLongerSideOnTheGroundNotInDegrees() {
        // A degree of longitude is shorter than a degree of latitude everywhere but the
        // equator, and near the pole it is much shorter.
        XCTAssertEqual(SplitAxis.best(for: BBox(minLon: 0, minLat: 0, maxLon: 10, maxLat: 5)),
                       .longitude)
        XCTAssertEqual(SplitAxis.best(for: BBox(minLon: 0, minLat: 0, maxLon: 5, maxLat: 10)),
                       .latitude)
        // Equal in degrees at 70 deg N: the box is far taller than it is wide on the ground.
        XCTAssertEqual(SplitAxis.best(for: BBox(minLon: 20, minLat: 69, maxLon: 24, maxLat: 73)),
                       .latitude)
        XCTAssertEqual(SplitAxis.best(for: .empty), .longitude)
    }
}
