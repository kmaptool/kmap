import XCTest
@testable import kmap

/// The numbers a reader sees, and the box every stage measures ground with.
///
/// `BBox` is not decoration: the elevation stage asks it which degree cells to fetch, the
/// region list asks it how big a build will be, and the split asks it what it covers. A
/// box wrong by a degree is a missing row of contours at the edge of the map.
final class FormatTests: XCTestCase {

    // MARK: Sizes and times

    func testBytesUseTheDecimalUnitsDownloadSitesQuote() {
        XCTAssertEqual(Fmt.bytes(0), "0 B")
        XCTAssertEqual(Fmt.bytes(999), "999 B")
        XCTAssertEqual(Fmt.bytes(1_000), "1 kB")
        XCTAssertEqual(Fmt.bytes(999_999), "1000 kB")
        XCTAssertEqual(Fmt.bytes(1_000_000), "1.0 MB")
        XCTAssertEqual(Fmt.bytes(41_900_000), "41.9 MB")
        XCTAssertEqual(Fmt.bytes(1_000_000_000), "1.00 GB")
        XCTAssertEqual(Fmt.bytes(6_680_000_000), "6.68 GB")
    }

    func testDurationsReadTheWayAPersonSaysThem() {
        XCTAssertEqual(Fmt.duration(0), "0s")
        XCTAssertEqual(Fmt.duration(48), "48s")
        XCTAssertEqual(Fmt.duration(59.4), "59s")
        // Rounded first, then split: 59.6 s is a minute, not "60s".
        XCTAssertEqual(Fmt.duration(59.6), "1m 00s")
        XCTAssertEqual(Fmt.duration(60), "1m 00s")
        XCTAssertEqual(Fmt.duration(252), "4m 12s")
        XCTAssertEqual(Fmt.duration(3_600), "1h 00m")
        XCTAssertEqual(Fmt.duration(3_780), "1h 03m")
    }

    func testNonsenseTimesAndRatesShowADashRatherThanANumber() {
        // A rate is computed by dividing by an elapsed time that can be zero on the first
        // tick, and a remaining time by dividing by a rate that can be zero.
        XCTAssertEqual(Fmt.duration(.nan), "—")
        XCTAssertEqual(Fmt.duration(.infinity), "—")
        XCTAssertEqual(Fmt.duration(-1), "—")
        XCTAssertEqual(Fmt.duration(60 * 60 * 48), "—")
        XCTAssertEqual(Fmt.rate(0), "—")
        XCTAssertEqual(Fmt.rate(-5), "—")
        XCTAssertEqual(Fmt.rate(.nan), "—")
        XCTAssertEqual(Fmt.rate(2_500_000), "2.5 MB/s")
    }

    func testPercentIsClampedAndNeverShowsNaN() {
        XCTAssertEqual(Fmt.percent(0), "  0%")
        XCTAssertEqual(Fmt.percent(0.5), " 50%")
        XCTAssertEqual(Fmt.percent(1), "100%")
        XCTAssertEqual(Fmt.percent(1.4), "100%")
        XCTAssertEqual(Fmt.percent(-3), "  0%")
        XCTAssertEqual(Fmt.percent(.nan), "  0%")
    }

    func testCoordinatesCarryTheCompassPointRatherThanASign() {
        XCTAssertEqual(Fmt.coord(44.5, lat: true), "44.50°N")
        XCTAssertEqual(Fmt.coord(-33.87, lat: true), "33.87°S")
        XCTAssertEqual(Fmt.coord(34.1, lat: false), "34.10°E")
        XCTAssertEqual(Fmt.coord(-71.2, lat: false), "71.20°W")
        // Zero belongs to the northern and eastern side, as every tile name has it.
        XCTAssertEqual(Fmt.coord(0, lat: true), "0.00°N")
        XCTAssertEqual(Fmt.coord(0, lat: false), "0.00°E")
    }

    // MARK: The box

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
        XCTAssertEqual(whole.snappedOutward(margin: 0.5),
                       BBox(minLon: 4, minLat: 48, maxLon: 8, maxLat: 52))
    }

    func testSnappingWorksBelowTheEquatorAndWestOfGreenwich() {
        // Rounding towards zero instead of down puts a southern box one degree north of
        // where it belongs.
        let box = BBox(minLon: -71.2, minLat: -33.9, maxLon: -70.3, maxLat: -33.1)
        XCTAssertEqual(box.snappedOutward(),
                       BBox(minLon: -72, minLat: -34, maxLon: -70, maxLat: -33))
    }

    func testTheTileCountIsTheNumberOfDegreeCellsCovered() {
        XCTAssertEqual(BBox(minLon: 5.73, minLat: 49.45, maxLon: 6.53, maxLat: 50.18)
                        .demTileCount, 4)
        XCTAssertEqual(BBox(minLon: 0, minLat: 0, maxLon: 1, maxLat: 1).demTileCount, 1)
        // A point is still one cell to fetch, not none.
        XCTAssertEqual(BBox(minLon: 6.1, minLat: 49.6, maxLon: 6.1, maxLat: 49.6)
                        .demTileCount, 1)
    }

    func testOneBoxRoundTheWholeWorldIsWhatRingsExistToAvoid() {
        // A region reaching across 180° drawn as one box asks Copernicus for a hemisphere;
        // this is the number that says so, and RegionIndex keeps a box per ring because of
        // it. Pinned here so the cost stays visible.
        XCTAssertEqual(BBox(minLon: -180, minLat: 40, maxLon: 180, maxLat: 80)
                        .demTileCount, 360 * 40)
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
        XCTAssertEqual(box.distance(toLat: 5, lon: 10), 0)          // on the edge
        XCTAssertEqual(box.distance(toLat: 5, lon: 13), 3, accuracy: 1e-9)
        XCTAssertEqual(box.distance(toLat: -4, lon: 5), 4, accuracy: 1e-9)
        // Off a corner, both directions count.
        XCTAssertEqual(box.distance(toLat: 13, lon: 14), 5, accuracy: 1e-9)
    }

    func testTheAreaArgumentIsTheOrderPyhgtmapExpects() {
        // minlon:minlat:maxlon:maxlat -- swapping a pair silently contours the wrong ground.
        XCTAssertEqual(BBox(minLon: 5.73, minLat: 49.45, maxLon: 6.53, maxLat: 50.18)
                        .areaArgument, "5.7300:49.4500:6.5300:50.1800")
    }

    func testABoxSurvivesBeingWrittenToSettingsAndReadBack() throws {
        let box = BBox(minLon: -71.2, minLat: -33.9, maxLon: -70.3, maxLat: -33.1)
        let data = try JSONEncoder().encode(box)
        XCTAssertEqual(try JSONDecoder().decode(BBox.self, from: data), box)
    }
}
