import XCTest
@testable import kmap

/// Whether the tiles of a map cover the ground they claim. A spot inside the map's own box
/// belonging to no tile draws as blank paper, since a tile carries the sea fill and the DEM.
final class MapCoverageTests: XCTestCase {

    private func tile(_ name: String, _ minLat: Double, _ minLon: Double,
                      _ maxLat: Double, _ maxLon: Double) -> MapCoverage.Tile {
        MapCoverage.Tile(name: name, minLat: minLat, minLon: minLon,
                         maxLat: maxLat, maxLon: maxLon)
    }

    // MARK: Reading the bounds out of a TRE

    /// Garmin states an angle as a 24-bit share of the circle.
    func testTheAngleIsAShareOfTheWholeCircle() {
        XCTAssertEqual(MapCoverage.degrees(0), 0, accuracy: 1e-9)
        XCTAssertEqual(MapCoverage.degrees(Int32(1 << 22)), 90, accuracy: 1e-9)
        XCTAssertEqual(MapCoverage.degrees(Int32(-(1 << 22))), -90, accuracy: 1e-9)
    }

    func testASignedTwentyFourBitValueReadsBothWays() {
        XCTAssertEqual(MapCoverage.signed24([0x01, 0x00, 0x00], at: 0), 1)
        // 0x800000 is the sign bit: the smallest negative there is.
        XCTAssertEqual(MapCoverage.signed24([0x00, 0x00, 0x80], at: 0), -(1 << 23))
        XCTAssertEqual(MapCoverage.signed24([0xFF, 0xFF, 0xFF], at: 0), -1)
        XCTAssertNil(MapCoverage.signed24([0x01, 0x02], at: 0), "two bytes are not three")
    }

    /// A TRE header opens with its own length and the words `GARMIN TRE`, and states its
    /// four corners at 0x15 in the order north, east, south, west.
    func testTheBoundsComeOutOfATREHeader() {
        var header = [UInt8](repeating: 0, count: 0x30)
        header[0] = 0x30
        for (at, byte) in Array("GARMIN TRE".utf8).enumerated() { header[2 + at] = byte }
        func put(_ value: Int, at offset: Int) {
            let raw = value < 0 ? value + (1 << 24) : value
            header[offset] = UInt8(raw & 0xFF)
            header[offset + 1] = UInt8((raw >> 8) & 0xFF)
            header[offset + 2] = UInt8((raw >> 16) & 0xFF)
        }
        put(1 << 22, at: 0x15)          // north 90
        put(1 << 21, at: 0x18)          // east 45
        put(0, at: 0x1B)                // south 0
        put(-(1 << 21), at: 0x1E)       // west -45

        let box = MapCoverage.bounds(ofTRE: header)
        XCTAssertNotNil(box)
        XCTAssertEqual(box!.maxLat, 90, accuracy: 1e-9)
        XCTAssertEqual(box!.maxLon, 45, accuracy: 1e-9)
        XCTAssertEqual(box!.minLat, 0, accuracy: 1e-9)
        XCTAssertEqual(box!.minLon, -45, accuracy: 1e-9)
    }

    func testSomethingThatIsNotATREIsRefused() {
        var header = [UInt8](repeating: 0, count: 0x30)
        for (at, byte) in Array("GARMIN RGN".utf8).enumerated() { header[2 + at] = byte }
        XCTAssertNil(MapCoverage.bounds(ofTRE: header))
        XCTAssertNil(MapCoverage.bounds(ofTRE: [0x10, 0x00]), "too short to say anything")
    }

    // MARK: The check itself

    func testTilesThatPartitionTheirBoxLeaveNoHoles() {
        let report = MapCoverage.check([
            tile("a", 0, 0, 1, 1), tile("b", 0, 1, 1, 2),
            tile("c", 1, 0, 2, 1), tile("d", 1, 1, 2, 2),
        ], step: 0.25)
        XCTAssertNotNil(report)
        XCTAssertTrue(report!.holes.isEmpty)
        XCTAssertEqual(report!.sampled, 64)
        XCTAssertEqual(report!.minLat, 0)
        XCTAssertEqual(report!.maxLon, 2)
    }

    /// One of the four missing: the samples over it belong to no tile.
    func testAMissingTileIsFound() {
        let report = MapCoverage.check([
            tile("a", 0, 0, 1, 1), tile("b", 0, 1, 1, 2), tile("c", 1, 0, 2, 1),
        ], step: 0.25)
        XCTAssertEqual(report!.holes.count, 16)
        XCTAssertTrue(report!.holes.allSatisfy { $0.lat > 1 && $0.lon > 1 })
    }

    /// The grid is offset by half a step so a sample never lands on a shared edge, where
    /// both neighbours claim it and a gap of nothing between them would read as covered.
    func testASampleNeverLandsOnASharedEdge() {
        // Two tiles a hair apart: 1.0 to 1.001 belongs to neither.
        let report = MapCoverage.check([
            tile("a", 0, 0, 1, 2), tile("b", 1.001, 0, 2, 2),
        ], step: 0.5)
        // The gap is far thinner than the step, so no sample lands in it.
        XCTAssertTrue(report!.holes.isEmpty)
        // A gap wider than the step is found.
        let wide = MapCoverage.check([
            tile("a", 0, 0, 1, 2), tile("b", 1.6, 0, 2, 2),
        ], step: 0.25)
        XCTAssertFalse(wide!.holes.isEmpty)
    }

    func testNoTilesIsNoReport() {
        XCTAssertNil(MapCoverage.check([], step: 0.25))
        XCTAssertNil(MapCoverage.check([tile("a", 0, 0, 1, 1)], step: 0))
    }

    func testASingleTileCoversItself() {
        let report = MapCoverage.check([tile("only", 44, 33, 45, 34)], step: 0.25)
        XCTAssertTrue(report!.holes.isEmpty)
        XCTAssertEqual(report!.sampled, 16)
    }
}
