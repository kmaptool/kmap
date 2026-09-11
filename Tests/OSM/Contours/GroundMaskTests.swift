import XCTest
@testable import kmap

/// Cutting the contours to the ground the map actually has data for.
///
/// Cutting too little draws mountains over unmapped ground and cutting too much loses
/// real slopes; a line that loses points falls apart into clean pieces.
final class GroundMaskTests: XCTestCase {

    // MARK: The mask

    private func mask(_ poly: String) -> GroundMask? {
        RegionOutline.parse(poly).flatMap { GroundMask(rings: $0) }
    }

    func testInsideIsInsideAndFarOutsideIsNot() throws {
        let m = try XCTUnwrap(mask(PolyFixture.square))
        XCTAssertTrue(m.contains(lat: 40.5, lon: 10.5))
        XCTAssertFalse(m.contains(lat: 40.5, lon: 12.0))
        XCTAssertFalse(m.contains(lat: 43.0, lon: 10.5))
        XCTAssertFalse(m.contains(lat: 40.5, lon: 8.0))
    }

    func testTheMaskReachesAShadePastTheOutline() throws {
        // An extract is cut a shade generously against its own outline, so a contour meets
        // the data's edge rather than stopping short of it.
        let m = try XCTUnwrap(mask(PolyFixture.square))
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
        let a = try XCTUnwrap(RegionOutline.parse(PolyFixture.square))
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
        let m = try XCTUnwrap(mask(PolyFixture.square))
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
        let m = try XCTUnwrap(mask(PolyFixture.square))
        let outside = line([(43.2, 42.5), (43.3, 42.6), (43.4, 42.7)])
        XCTAssertTrue(m.clip([outside]).isEmpty)
    }

    func testALineEntirelyInsideComesThroughUntouched() throws {
        let m = try XCTUnwrap(mask(PolyFixture.square))
        let ring = line([(40.4, 10.4), (40.4, 10.6), (40.6, 10.6), (40.6, 10.4)],
                        closed: true)
        let kept = m.clip([ring])
        XCTAssertEqual(kept.count, 1)
        XCTAssertEqual(kept[0].points.count, 4)
        XCTAssertTrue(kept[0].closed, "an untouched ring stays a ring")
    }

    func testACutRingStopsClaimingToBeClosed() throws {
        // A ring with a bite out of it drawn closed would invent an edge across the gap.
        let m = try XCTUnwrap(mask(PolyFixture.square))
        let ring = line([(40.5, 10.5), (40.5, 11.4), (40.6, 11.4), (40.6, 10.5)],
                        closed: true)
        let cut = m.clip([ring])
        XCTAssertTrue(cut.allSatisfy { !$0.closed })
    }

    func testASingleStrandedPointIsDroppedNotDrawn() throws {
        // One point on covered ground between two excursions is not a line.
        let m = try XCTUnwrap(mask(PolyFixture.square))
        let graze = line([(40.5, 11.4), (40.5, 10.9), (40.5, 11.4)])
        XCTAssertTrue(m.clip([graze]).isEmpty)
    }

    func testTheSameCoordinateGetsTheSameAnswerFromEveryCell() throws {
        // A line crossing a cell edge exists as two halves asking about the same point; a
        // differing answer would cut one half and leave the other dangling.
        let m = try XCTUnwrap(mask(PolyFixture.square))
        for lon in stride(from: 9.9, through: 11.2, by: 0.01) {
            XCTAssertEqual(m.contains(lat: 41.0, lon: lon),
                           m.contains(lat: 41.0, lon: lon))
            let a = m.contains(lat: 40.9999999, lon: lon)
            let b = m.contains(lat: 40.9999999, lon: lon)
            XCTAssertEqual(a, b)
        }
    }
}
