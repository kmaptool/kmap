import XCTest
@testable import kmap

/// The degree-cell trim: which 1°x1° rectangles of elevation a region's outline keeps.
final class RegionOutlineGeometryTests: XCTestCase {

    /// A diamond around (10, 50), reaching one third of a degree each way.
    private let diamond = [RegionOutline.Ring(subtract: false, points: [
        (10.0, 49.7), (10.3, 50.0), (10.0, 50.3), (9.7, 50.0), (10.0, 49.7)
    ])]

    private func touches(lon: Double, lat: Double, margin: Double = 0.0) -> Bool {
        RegionOutline.rectTouches(diamond,
                                  minLon: lon - margin, minLat: lat - margin,
                                  maxLon: lon + 1 + margin, maxLat: lat + 1 + margin)
    }

    func testACellHoldingTheRegionIsKept() {
        // Every vertex inside the cell: the region sits wholly within one degree.
        XCTAssertTrue(touches(lon: 9.5, lat: 49.5))
    }

    func testTheBorderCellIsKeptFromEitherSide() {
        // The diamond pokes into each of these cells without containing them.
        XCTAssertTrue(touches(lon: 9.0, lat: 49.0))
        XCTAssertTrue(touches(lon: 10.0, lat: 50.0))
    }

    func testACellInsideAHugeRingIsKept() {
        // No vertex near the cell and no edge crossing it: containment alone keeps it.
        let country = [RegionOutline.Ring(subtract: false, points: [
            (0.0, 40.0), (20.0, 40.0), (20.0, 60.0), (0.0, 60.0), (0.0, 40.0)
        ])]
        XCTAssertTrue(RegionOutline.rectTouches(country, minLon: 10, minLat: 50,
                                                maxLon: 11, maxLat: 51))
    }

    func testTheForeignInteriorIsDropped() {
        XCTAssertFalse(touches(lon: 12.0, lat: 50.0), "two degrees east of the region")
        XCTAssertFalse(touches(lon: 9.5, lat: 52.0), "two degrees north of it")
    }

    func testAnEdgeSlicingACornerKeepsTheCellWithoutAnyVertexInside() {
        // One long segment clips the cell's corner; neither endpoint is in the cell and
        // no cell corner is inside the sliver either.
        let sliver = [RegionOutline.Ring(subtract: false, points: [
            (8.0, 51.05), (12.0, 50.55), (12.0, 50.6), (8.0, 51.1), (8.0, 51.05)
        ])]
        XCTAssertTrue(RegionOutline.rectTouches(sliver, minLon: 9, minLat: 50,
                                                maxLon: 10, maxLat: 51))
    }

    func testAHoleNeverCostsACell() {
        // Subtract-rings are ignored: a hole lies inside the region, and dropping its
        // cells would cut ground the map still draws around.
        let holed = diamond + [RegionOutline.Ring(subtract: true, points: [
            (9.9, 49.9), (10.1, 49.9), (10.1, 50.1), (9.9, 50.1), (9.9, 49.9)
        ])]
        XCTAssertTrue(RegionOutline.rectTouches(holed, minLon: 9.5, minLat: 49.5,
                                                maxLon: 10.5, maxLat: 50.5))
    }

    func testTheMarginSavesABorderRunningAlongTheCellEdge() {
        // The ring's westernmost point sits exactly on this cell's eastern edge; with
        // the tenth-of-a-degree margin the caller adds, the cell stays.
        XCTAssertTrue(touches(lon: 8.7, lat: 49.5, margin: 0.1))
    }
}
