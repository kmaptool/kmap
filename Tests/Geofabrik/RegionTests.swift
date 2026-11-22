import XCTest

@testable import kmap

final class RegionTests: XCTestCase {
    private func region(_ rings: [[(lon: Double, lat: Double)]], boxes: [BBox]? = nil) -> Region {
        let around = rings.map { ring -> BBox in
            var box = BBox.empty
            for vertex in ring { box.extend(lon: vertex.lon, lat: vertex.lat) }
            return box
        }
        var all = BBox.empty
        for box in boxes ?? around {
            all.extend(lon: box.minLon, lat: box.minLat)
            all.extend(lon: box.maxLon, lat: box.maxLat)
        }
        return Region(id: "r", name: "r", parentID: nil, pbfURL: nil, bbox: all, boxes: boxes ?? around, rings: rings)
    }

    private func square(
        _ minLon: Double,
        _ minLat: Double,
        _ maxLon: Double,
        _ maxLat: Double
    )
        -> [(lon: Double, lat: Double)]
    {
        [(minLon, minLat), (maxLon, minLat), (maxLon, maxLat), (minLon, maxLat)]
    }

    /// Equal-area: 10 deg of longitude between the equator and 30 deg hold as much as the
    /// same 10 deg between 30 and 90.
    func testTheOutlineAreaIsOfTheGroundNotOfTheDegrees() {
        XCTAssertEqual(region([square(0, 0, 10, 30)]).outlineArea, 5, accuracy: 1e-9)
        XCTAssertEqual(region([square(0, 30, 10, 90)]).outlineArea, 5, accuracy: 1e-9)
        XCTAssertEqual(region([square(0, -30, 10, 0)]).outlineArea, 5, accuracy: 1e-9)
    }

    func testTheAreaIsTheSameWhicheverWayARingRuns() {
        XCTAssertEqual(region([square(0, 0, 10, 30).reversed()]).outlineArea, 5, accuracy: 1e-9)
    }

    /// A ring inside another is ground the region does not hold, as `holds` reads it.
    func testARingInsideAnotherIsTakenAway() {
        let holed = region([square(0, 0, 10, 30), square(4, 0, 6, 30)])
        XCTAssertFalse(holed.holds(lat: 10, lon: 5))
        XCTAssertTrue(holed.holds(lat: 10, lon: 2))
        XCTAssertEqual(holed.outlineArea, 4, accuracy: 1e-9)
        // An island in the hole is the region's again.
        let island = region([square(0, 0, 10, 30), square(4, 0, 6, 30), square(4.5, 0, 5.5, 30)])
        XCTAssertTrue(island.holds(lat: 10, lon: 5))
        XCTAssertEqual(island.outlineArea, 4.5, accuracy: 1e-9)
    }

    /// The triangle starts on the diamond's westmost vertex: a ray from there crosses the
    /// diamond once, and that alone must not make the triangle a hole. The hole in the
    /// test above has every vertex on the outer ring's edge, and is a hole all the same.
    func testRingsTouchingAtAVertexAddUp() {
        let diamond: [(lon: Double, lat: Double)] = [(0, 10), (5, 0), (10, 10), (5, 20)]
        let triangle: [(lon: Double, lat: Double)] = [(0, 10), (-5, 15), (-5, 5)]
        let both = region([diamond, triangle]).outlineArea
        XCTAssertEqual(both, region([diamond]).outlineArea + region([triangle]).outlineArea, accuracy: 1e-9)
        XCTAssertEqual(region([triangle, diamond]).outlineArea, both, accuracy: 1e-9)
    }

    func testRingsApartAddUp() {
        XCTAssertEqual(region([square(0, 0, 10, 30), square(170, 0, 180, 30)]).outlineArea, 10, accuracy: 1e-9)
    }

    /// An outline that never parsed is measured by its boxes.
    func testARegionWithoutAnOutlineIsMeasuredByItsBoxes() {
        let boxed = region([], boxes: [BBox(minLon: 0, minLat: 0, maxLon: 10, maxLat: 30)])
        XCTAssertEqual(boxed.outlineArea, 5, accuracy: 1e-9)
        XCTAssertEqual(region([], boxes: []).outlineArea, 0)
    }

    func testABoxTheOutlineDoesNotRunThroughIsHeldWholeOrNotAtAll() {
        let holed = region([square(0, 0, 10, 30), square(4, 10, 6, 20)])
        XCTAssertEqual(holed.holdsWhole(BBox(minLon: 1, minLat: 1, maxLon: 3, maxLat: 5)), true)
        XCTAssertEqual(holed.holdsWhole(BBox(minLon: 4.5, minLat: 12, maxLon: 5.5, maxLat: 18)), false, "in the hole")
        XCTAssertEqual(holed.holdsWhole(BBox(minLon: 20, minLat: 1, maxLon: 21, maxLat: 2)), false)
        XCTAssertNil(holed.holdsWhole(BBox(minLon: 9, minLat: 1, maxLon: 11, maxLat: 2)), "across the outer ring")
        XCTAssertNil(holed.holdsWhole(BBox(minLon: 3, minLat: 12, maxLon: 5, maxLat: 13)), "across the hole's ring")
        XCTAssertNil(holed.holdsWhole(BBox(minLon: -5, minLat: -5, maxLon: 15, maxLat: 35)), "around it all")
        XCTAssertNil(region([], boxes: [BBox(minLon: 0, minLat: 0, maxLon: 10, maxLat: 30)]).holdsWhole(.empty))
    }

    /// Whatever it says of a box, every point of the box says the same.
    func testTheWholeBoxAnswerIsEveryPointsAnswer() {
        let ragged: [(lon: Double, lat: Double)] = [
            (0, 0), (6, 1), (12, -2), (15, 6), (9, 5), (11, 12), (4, 9), (-3, 13), (1, 6), (-4, 3)
        ]
        let outline = region([ragged, square(3, 3, 5, 5)])
        var random = SplitMix64(state: 7)
        var whole = 0
        for _ in 0..<2000 {
            let lon = Double(random.next() % 2400) / 100 - 6, lat = Double(random.next() % 2000) / 100 - 4
            let box = BBox(
                minLon: lon,
                minLat: lat,
                maxLon: lon + Double(random.next() % 300) / 100,
                maxLat: lat + Double(random.next() % 300) / 100
            )
            guard let answer = outline.holdsWhole(box) else { continue }
            whole += 1
            for cell in RegionSuggestion.cells(over: box, steps: 5) {
                XCTAssertEqual(outline.holds(lat: cell.lat, lon: cell.lon), answer, "\(box)")
            }
        }
        XCTAssertGreaterThan(whole, 200, "the boxes were not all across the outline")
    }

    /// An outline around 0 deg, 0 deg holds ground of every sign, and its area counts
    /// both sides of the equator.
    func testAnOutlineAroundTheOriginHoldsEveryQuarter() {
        let box = BBox(minLon: -2, minLat: -1, maxLon: 2, maxLat: 1)
        let around = Region(
            id: "o",
            name: "o",
            parentID: nil,
            pbfURL: nil,
            bbox: box,
            boxes: [box],
            rings: [[(-2, -1), (2, -1), (2, 1), (-2, 1)]]
        )
        for (lon, lat) in [(1.5, 0.5), (-1.5, 0.5), (-1.5, -0.5), (1.5, -0.5), (0.0, 0.0)] {
            XCTAssertTrue(around.holds(lat: lat, lon: lon), "\(lon), \(lat)")
        }
        XCTAssertFalse(around.holds(lat: 0, lon: 2.5))
        XCTAssertFalse(around.holds(lat: -1.5, lon: 0))
        XCTAssertEqual(around.holdsWhole(BBox(minLon: -0.5, minLat: -0.5, maxLon: 0.5, maxLat: 0.5)), true)
        XCTAssertEqual(around.holdsWhole(BBox(minLon: 3, minLat: -0.5, maxLon: 4, maxLat: 0.5)), false)
        XCTAssertNil(around.holdsWhole(BBox(minLon: -3, minLat: -0.5, maxLon: 0, maxLat: 0.5)))
        // 4 deg of longitude over 2 deg of latitude at the equator: 4 * 2 * sin(1 deg).
        XCTAssertEqual(around.outlineArea, 4 * 2 * sin(Double.pi / 180), accuracy: 1e-9)
    }
}
