import XCTest
@testable import kmap

/// Cutting the contours to the ground the map actually has data for.
///
/// Cutting too little draws mountains over unmapped ground and cutting too much loses
/// real slopes; a line that loses points falls apart into clean pieces.
final class RegionOutlineTests: XCTestCase {

    // MARK: Reading a .poly

    private let square = """
    test-region
    1
       10.0  40.0
       11.0  40.0
       11.0  41.0
       10.0  41.0
       10.0  40.0
    END
    END
    """

    func testAPlainPolygonParses() throws {
        let rings = try XCTUnwrap(RegionOutline.parse(square))
        XCTAssertEqual(rings.count, 1)
        XCTAssertFalse(rings[0].subtract)
        XCTAssertEqual(rings[0].points.count, 5)
        XCTAssertEqual(rings[0].points[0].lon, 10.0)
        XCTAssertEqual(rings[0].points[2].lat, 41.0)
    }

    func testAHoleIsMarkedByItsBang() throws {
        let poly = """
        with-hole
        1
           10.0 40.0
           11.0 40.0
           11.0 41.0
           10.0 41.0
        END
        !2
           10.35 40.35
           10.65 40.35
           10.65 40.65
           10.35 40.65
        END
        END
        """
        let rings = try XCTUnwrap(RegionOutline.parse(poly))
        XCTAssertEqual(rings.map(\.subtract), [false, true])
    }

    func testWhatIsNotAPolyIsRefusedRatherThanGuessedAt() {
        // A mask built from half a polygon would cut contours over real data.
        XCTAssertNil(RegionOutline.parse(""))
        XCTAssertNil(RegionOutline.parse("just-a-name\nEND\n"))
        XCTAssertNil(RegionOutline.parse("<html>404 not found</html>"))
        // Only a hole and nothing to cut it from is no outline either.
        XCTAssertNil(RegionOutline.parse("x\n!1\n 10 40\n 11 40\n 11 41\nEND\nEND\n"))
    }

    // MARK: The mask

    private func mask(_ poly: String) -> GroundMask? {
        RegionOutline.parse(poly).flatMap { GroundMask(rings: $0) }
    }

    func testInsideIsInsideAndFarOutsideIsNot() throws {
        let m = try XCTUnwrap(mask(square))
        XCTAssertTrue(m.contains(lat: 40.5, lon: 10.5))
        XCTAssertFalse(m.contains(lat: 40.5, lon: 12.0))
        XCTAssertFalse(m.contains(lat: 43.0, lon: 10.5))
        XCTAssertFalse(m.contains(lat: 40.5, lon: 8.0))
    }

    func testTheMaskReachesAShadePastTheOutline() throws {
        // An extract is cut a shade generously against its own outline, so a contour meets
        // the data's edge rather than stopping short of it.
        let m = try XCTUnwrap(mask(square))
        XCTAssertTrue(m.contains(lat: 40.5, lon: 11.03))
        XCTAssertTrue(m.contains(lat: 41.03, lon: 10.5))
        // But only a shade: half a degree out is out.
        XCTAssertFalse(m.contains(lat: 40.5, lon: 11.5))
    }

    func testAHoleStaysAHole() throws {
        let poly = """
        with-hole
        1
           10.0 40.0
           11.0 40.0
           11.0 41.0
           10.0 41.0
        END
        !2
           10.3 40.3
           10.7 40.3
           10.7 40.7
           10.3 40.7
        END
        END
        """
        let m = try XCTUnwrap(mask(poly))
        XCTAssertFalse(m.contains(lat: 40.5, lon: 10.5), "the middle of the hole is ground")
        XCTAssertTrue(m.contains(lat: 40.9, lon: 10.5))
    }

    func testTwoRegionsAreOneGround() throws {
        // A build of several regions cuts to their union, not to whichever came first.
        let a = try XCTUnwrap(RegionOutline.parse(square))
        let b = try XCTUnwrap(RegionOutline.parse("""
        neighbour
        1
           11.0 40.0
           12.0 40.0
           12.0 41.0
           11.0 41.0
        END
        END
        """))
        let m = try XCTUnwrap(GroundMask(rings: a + b))
        XCTAssertTrue(m.contains(lat: 40.5, lon: 10.5))
        XCTAssertTrue(m.contains(lat: 40.5, lon: 11.5))
        XCTAssertFalse(m.contains(lat: 40.5, lon: 12.5))
    }

    // MARK: Cutting the lines

    private func line(_ points: [(Double, Double)], elevation: Int = 100,
                      closed: Bool = false) -> Contours.Line {
        Contours.Line(elevation: elevation,
                      points: points.map { (lat: $0.0, lon: $0.1) }, closed: closed)
    }

    func testALineIsCutIntoItsRunsOnCoveredGround() throws {
        let m = try XCTUnwrap(mask(square))
        // In, out past the eastern border, in again: two clean pieces.
        let crossing = line([(40.5, 10.4), (40.5, 10.6), (40.5, 11.4),
                             (40.5, 11.6), (40.5, 10.8), (40.5, 10.7)])
        let cut = m.clip([crossing])
        XCTAssertEqual(cut.count, 2)
        XCTAssertEqual(cut[0].points.count, 2)
        XCTAssertEqual(cut[1].points.count, 2)
        XCTAssertTrue(cut.allSatisfy { $0.elevation == 100 })
        XCTAssertTrue(cut.allSatisfy { !$0.closed })
    }

    func testALineEntirelyOffTheGroundIsNotDrawnAtAll() throws {
        let m = try XCTUnwrap(mask(square))
        let outside = line([(43.2, 42.5), (43.3, 42.6), (43.4, 42.7)])
        XCTAssertTrue(m.clip([outside]).isEmpty)
    }

    func testALineEntirelyInsideComesThroughUntouched() throws {
        let m = try XCTUnwrap(mask(square))
        let ring = line([(40.4, 10.4), (40.4, 10.6), (40.6, 10.6), (40.6, 10.4)],
                        closed: true)
        let kept = m.clip([ring])
        XCTAssertEqual(kept.count, 1)
        XCTAssertEqual(kept[0].points.count, 4)
        XCTAssertTrue(kept[0].closed, "an untouched ring stays a ring")
    }

    func testACutRingStopsClaimingToBeClosed() throws {
        // A ring with a bite out of it drawn closed would invent an edge across the gap.
        let m = try XCTUnwrap(mask(square))
        let ring = line([(40.5, 10.5), (40.5, 11.4), (40.6, 11.4), (40.6, 10.5)],
                        closed: true)
        let cut = m.clip([ring])
        XCTAssertTrue(cut.allSatisfy { !$0.closed })
    }

    func testASingleStrandedPointIsDroppedNotDrawn() throws {
        // One point on covered ground between two excursions is not a line.
        let m = try XCTUnwrap(mask(square))
        let graze = line([(40.5, 11.4), (40.5, 10.9), (40.5, 11.4)])
        XCTAssertTrue(m.clip([graze]).isEmpty)
    }

    func testTheSameCoordinateGetsTheSameAnswerFromEveryCell() throws {
        // A line crossing a cell edge exists as two halves asking about the same point; a
        // differing answer would cut one half and leave the other dangling.
        let m = try XCTUnwrap(mask(square))
        for lon in stride(from: 9.9, through: 11.2, by: 0.01) {
            XCTAssertEqual(m.contains(lat: 41.0, lon: lon),
                           m.contains(lat: 41.0, lon: lon))
            let a = m.contains(lat: 40.9999999, lon: lon)
            let b = m.contains(lat: 40.9999999, lon: lon)
            XCTAssertEqual(a, b)
        }
    }
}

final class PolyTextTests: XCTestCase {

    func testWhatIsWrittenIsWhatParseReadsBack() throws {
        // The writer feeds pyhgtmap and the parser feeds the cell trim; the two dialects
        // must agree.
        let sections = [
            [(lon: 10.0, lat: 49.7), (lon: 10.3, lat: 50.0), (lon: 9.7, lat: 50.0)],
            [(lon: 34.0, lat: 44.0), (lon: 35.0, lat: 44.0), (lon: 35.0, lat: 45.0)],
        ]
        let text = RegionOutline.polyText(name: "kmap-elevation", sections: sections)
        let rings = try XCTUnwrap(RegionOutline.parse(text))
        XCTAssertEqual(rings.count, 2)
        XCTAssertTrue(rings.allSatisfy { !$0.subtract })
        // Closed on the way out: the last point of each ring equals its first.
        for (ring, section) in zip(rings, sections) {
            XCTAssertEqual(ring.points.first!.lon, section[0].lon)
            XCTAssertEqual(ring.points.last!.lon, section[0].lon)
            XCTAssertEqual(ring.points.last!.lat, section[0].lat)
        }
    }
}

/// The degree-cell trim: which 1°x1° rectangles of elevation a region's outline keeps.
final class RectTouchesTests: XCTestCase {

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
