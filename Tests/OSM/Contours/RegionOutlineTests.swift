import XCTest
@testable import kmap

/// The osmosis `.poly` dialect: what is read, what is refused, what is written back.
final class RegionOutlineTests: XCTestCase {

    func testAPlainPolygonParses() throws {
        let rings = try XCTUnwrap(RegionOutline.parse(PolyFixture.square))
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
