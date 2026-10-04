import XCTest

@testable import kmap

/// The box every stage measures ground with.
///
/// `BBox` is not decoration: the elevation stage asks it which degree cells to fetch, the
/// region list asks it how big a build will be, and the split asks it what it covers. A
/// box wrong by a degree is a missing row of contours at the edge of the map.
final class BBoxTests: XCTestCase {
    func testAnEmptyBoxIsNotValidUntilItHasSeenAPoint() {
        XCTAssertFalse(BBox.empty.isValid)
        XCTAssertEqual(BBox.empty.display, "—")
        XCTAssertEqual(BBox.empty.demTileCount, 0)
        var box = BBox.empty
        box.extend(lon: 6.1, lat: 49.6)
        XCTAssertTrue(box.isValid)
        XCTAssertEqual(box, BBox(minLon: 6.1, minLat: 49.6, maxLon: 6.1, maxLat: 49.6))
    }

    func testExtendingGrowsInBothDirections() {
        var box = BBox.empty
        for point in [(6.5, 49.4), (5.7, 50.2), (6.0, 49.9)] {
            box.extend(lon: point.0, lat: point.1)
        }
        XCTAssertEqual(box, BBox(minLon: 5.7, minLat: 49.4, maxLon: 6.5, maxLat: 50.2))
    }

    func testSnappingGoesOutwardsOnEverySide() {
        // Elevation is fetched by whole degrees, so a box that snapped inwards would leave
        // the edge of the map without contours.
        let box = BBox(minLon: 5.73, minLat: 49.45, maxLon: 6.53, maxLat: 50.18)
        XCTAssertEqual(box.snappedOutward(), BBox(minLon: 5, minLat: 49, maxLon: 7, maxLat: 51))
        // A box already on whole degrees is left where it is, not grown by one.
        let whole = BBox(minLon: 5, minLat: 49, maxLon: 7, maxLat: 51)
        XCTAssertEqual(whole.snappedOutward(), whole)
        XCTAssertEqual(
            whole.snappedOutward(margin: 0.5),
            BBox(minLon: 4, minLat: 48, maxLon: 8, maxLat: 52)
        )
    }

    func testSnappingWorksBelowTheEquatorAndWestOfGreenwich() {
        // Rounding towards zero instead of down puts a southern box one degree north of
        // where it belongs.
        let box = BBox(minLon: -71.2, minLat: -33.9, maxLon: -70.3, maxLat: -33.1)
        XCTAssertEqual(
            box.snappedOutward(),
            BBox(minLon: -72, minLat: -34, maxLon: -70, maxLat: -33)
        )
    }

    func testTheTileCountIsTheNumberOfDegreeCellsCovered() {
        XCTAssertEqual(
            BBox(minLon: 5.73, minLat: 49.45, maxLon: 6.53, maxLat: 50.18)
                .demTileCount,
            4
        )
        XCTAssertEqual(BBox(minLon: 0, minLat: 0, maxLon: 1, maxLat: 1).demTileCount, 1)
        // A point is still one cell to fetch, not none.
        XCTAssertEqual(
            BBox(minLon: 6.1, minLat: 49.6, maxLon: 6.1, maxLat: 49.6)
                .demTileCount,
            1
        )
    }

    func testOneBoxRoundTheWholeWorldIsWhatRingsExistToAvoid() {
        // A region reaching across 180° drawn as one box asks Copernicus for a hemisphere;
        // this is the number that says so, and RegionIndex keeps a box per ring because of
        // it. Pinned here so the cost stays visible.
        XCTAssertEqual(
            BBox(minLon: -180, minLat: 40, maxLon: 180, maxLat: 80)
                .demTileCount,
            360 * 40
        )
    }

    func testContainsIsInclusiveOnEveryEdge() {
        let box = BBox(minLon: 5, minLat: 49, maxLon: 7, maxLat: 51)
        XCTAssertTrue(box.contains(lat: 50, lon: 6))
        XCTAssertTrue(box.contains(lat: 49, lon: 5))
        XCTAssertTrue(box.contains(lat: 51, lon: 7))
        XCTAssertFalse(box.contains(lat: 48.9, lon: 6))
        XCTAssertFalse(box.contains(lat: 50, lon: 7.1))
    }

    func testDistanceIsZeroInsideAndGrowsOutwards() {
        let box = BBox(minLon: 0, minLat: 0, maxLon: 10, maxLat: 10)
        XCTAssertEqual(box.distance(toLat: 5, lon: 5), 0)
        XCTAssertEqual(box.distance(toLat: 5, lon: 10), 0)  // on the edge
        XCTAssertEqual(box.distance(toLat: 5, lon: 13), 3, accuracy: 1e-9)
        XCTAssertEqual(box.distance(toLat: -4, lon: 5), 4, accuracy: 1e-9)
        // Off a corner, both directions count.
        XCTAssertEqual(box.distance(toLat: 13, lon: 14), 5, accuracy: 1e-9)
    }

    func testTheAreaArgumentIsTheOrderPyhgtmapExpects() {
        // minlon:minlat:maxlon:maxlat -- swapping a pair silently contours the wrong ground.
        XCTAssertEqual(
            BBox(minLon: 5.73, minLat: 49.45, maxLon: 6.53, maxLat: 50.18)
                .areaArgument,
            "5.7300:49.4500:6.5300:50.1800"
        )
    }

    func testABoxSurvivesBeingWrittenToSettingsAndReadBack() throws {
        let box = BBox(minLon: -71.2, minLat: -33.9, maxLon: -70.3, maxLat: -33.1)
        let data = try JSONEncoder().encode(box)
        XCTAssertEqual(try JSONDecoder().decode(BBox.self, from: data), box)
    }
}
