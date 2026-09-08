import XCTest
@testable import kmap

/// The footprint both the build and the cost estimate fetch: box cells trimmed to the
/// region outlines, so the figure quoted and the fetch performed always agree.
final class ElevationFootprintTests: XCTestCase {

    private func region(_ id: String, _ boxes: [BBox]) -> Region {
        Region(id: id, name: id, parentID: nil, pbfURL: nil,
               bbox: boxes[0], boxes: boxes)
    }

    func testTheOutlineCutsTheCellsTheRegionNeverTouches() {
        // A 3×3 block of cells, with an outline occupying only the south-west corner.
        let box = BBox(minLon: 30, minLat: 40, maxLon: 33, maxLat: 43)
        let all = ElevationFootprint.cellOrigins(of: box)
        XCTAssertEqual(all.count, 9)
        let corner = RegionOutline.Ring(subtract: false, points: [
            (30.2, 40.2), (30.8, 40.2), (30.8, 40.8), (30.2, 40.8), (30.2, 40.2),
        ])
        let kept = ElevationFootprint.trim(all,
                                           ringsPerRegion: [(region("r", [box]), [corner])])
        XCTAssertEqual(kept.count, 1)
        XCTAssertEqual(kept.first?.lat, 40)
        XCTAssertEqual(kept.first?.lon, 30)
    }

    func testARegionWithoutAnOutlineKeepsEveryCellOfItsBoxes() {
        let box = BBox(minLon: 30, minLat: 40, maxLon: 32, maxLat: 42)
        let all = ElevationFootprint.cellOrigins(of: box)
        let kept = ElevationFootprint.trim(all,
                                           ringsPerRegion: [(region("r", [box]), nil)])
        XCTAssertEqual(kept.count, all.count, "no outline, no trim")
    }

    func testAMissingOutlineDoesNotLetAnotherRegionsOutlineCutItsCells() {
        // Two regions: one with an outline in the west, one without, in the east. The
        // eastern cells stay although the western outline never touches them.
        let west = region("w", [BBox(minLon: 30, minLat: 40, maxLon: 31, maxLat: 41)])
        let east = region("e", [BBox(minLon: 50, minLat: 40, maxLon: 51, maxLat: 41)])
        let all = ElevationFootprint.boxCells(of: [west, east])
        let ring = RegionOutline.Ring(subtract: false, points: [
            (30.2, 40.2), (30.8, 40.2), (30.8, 40.8), (30.2, 40.8), (30.2, 40.2),
        ])
        let kept = ElevationFootprint.trim(all, ringsPerRegion: [(west, [ring]),
                                                                 (east, nil)])
        XCTAssertEqual(kept.count, 2)
    }
}
