import XCTest

@testable import kmap

/// Whether the tiles of a map cover the ground they claim. A spot inside the map's own box
/// belonging to no tile draws as blank paper, since a tile carries the sea fill and the DEM.
final class MapCoverageTests: XCTestCase {
    private func tile(
        _ name: String,
        _ minLat: Double,
        _ minLon: Double,
        _ maxLat: Double,
        _ maxLon: Double
    ) -> MapCoverage.Tile {
        MapCoverage.Tile(
            name: name,
            minLat: minLat,
            minLon: minLon,
            maxLat: maxLat,
            maxLon: maxLon
        )
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
        put(1 << 22, at: 0x15)  // north 90
        put(1 << 21, at: 0x18)  // east 45
        put(0, at: 0x1B)  // south 0
        put(-(1 << 21), at: 0x1E)  // west -45

        let box = MapCoverage.bounds(ofTRE: header)
        XCTAssertNotNil(box)
        XCTAssertEqual(box!.maxLat, 90, accuracy: 1e-9)
        XCTAssertEqual(box!.maxLon, 45, accuracy: 1e-9)
        XCTAssertEqual(box!.minLat, 0, accuracy: 1e-9)
        XCTAssertEqual(box!.minLon, -45, accuracy: 1e-9)
    }

    /// A TRE header with these corners, in map units.
    private func treHeader(north: Int, east: Int, south: Int, west: Int) -> [UInt8] {
        var header = [UInt8](repeating: 0, count: 0x30)
        header[0] = 0x30
        for (at, byte) in Array("GARMIN TRE".utf8).enumerated() { header[2 + at] = byte }
        for (value, offset) in [(north, 0x15), (east, 0x18), (south, 0x1B), (west, 0x1E)] {
            let raw = value & 0xFF_FFFF
            header[offset] = UInt8(raw & 0xFF)
            header[offset + 1] = UInt8((raw >> 8) & 0xFF)
            header[offset + 2] = UInt8((raw >> 16) & 0xFF)
        }
        return header
    }

    /// mkgmap stores an east edge on 180 deg as -180.
    func testAnEastEdgeOn180IsNotReadAsMinus180() {
        let box = MapCoverage.bounds(
            ofTRE: treHeader(north: -(1 << 19), east: 1 << 23, south: -(1 << 20), west: 8_294_400)
        )
        XCTAssertEqual(box?.maxLon ?? 0, 180, accuracy: 1e-9)
        XCTAssertEqual(box?.minLon ?? 0, 177.978515625, accuracy: 1e-9)
    }

    /// An overview round the whole circle: both edges carry the same 24 bits.
    func testAnOverviewFromMinus180To180IsTheWholeCircle() {
        let box = MapCoverage.bounds(
            ofTRE: treHeader(north: -(1 << 19), east: 1 << 23, south: -(1 << 20), west: -(1 << 23))
        )
        XCTAssertEqual(box?.minLon ?? 0, -180, accuracy: 1e-9)
        XCTAssertEqual(box?.maxLon ?? 0, 180, accuracy: 1e-9)
    }

    /// An overview across 180 deg: its east edge is read past 180.
    func testAnOverviewOverTheSeamRunsPast180() {
        let box = MapCoverage.bounds(
            ofTRE: treHeader(north: -(1 << 19), east: -(1 << 22), south: -(1 << 20), west: 1 << 22)
        )
        XCTAssertEqual(box?.minLon ?? 0, 90, accuracy: 1e-9)
        XCTAssertEqual(box?.maxLon ?? 0, 270, accuracy: 1e-9)
    }

    /// Only the east edge flips: a west edge on -180 stays there.
    func testAWestEdgeOnMinus180StaysThere() {
        let box = MapCoverage.bounds(
            ofTRE: treHeader(north: -(1 << 19), east: -(1 << 22), south: -(1 << 20), west: -(1 << 23))
        )
        XCTAssertEqual(box?.minLon ?? 0, -180, accuracy: 1e-9)
        XCTAssertEqual(box?.maxLon ?? 0, -90, accuracy: 1e-9)
    }

    func testSomethingThatIsNotATREIsRefused() {
        var header = [UInt8](repeating: 0, count: 0x30)
        for (at, byte) in Array("GARMIN RGN".utf8).enumerated() { header[2 + at] = byte }
        XCTAssertNil(MapCoverage.bounds(ofTRE: header))
        XCTAssertNil(MapCoverage.bounds(ofTRE: [0x10, 0x00]), "too short to say anything")
    }

    // MARK: The check itself

    func testTilesThatPartitionTheirBoxLeaveNoHoles() {
        let report = MapCoverage.check(
            [
                tile("a", 0, 0, 1, 1), tile("b", 0, 1, 1, 2),
                tile("c", 1, 0, 2, 1), tile("d", 1, 1, 2, 2)
            ],
            step: 0.25
        )
        XCTAssertNotNil(report)
        XCTAssertTrue(report!.holes.isEmpty)
        XCTAssertEqual(report!.sampled, 64)
        XCTAssertEqual(report!.minLat, 0)
        XCTAssertEqual(report!.maxLon, 2)
    }

    /// One of the four missing: the samples over it belong to no tile.
    func testAMissingTileIsFound() {
        let report = MapCoverage.check(
            [
                tile("a", 0, 0, 1, 1), tile("b", 0, 1, 1, 2), tile("c", 1, 0, 2, 1)
            ],
            step: 0.25
        )
        XCTAssertEqual(report!.holes.count, 16)
        XCTAssertTrue(report!.holes.allSatisfy { $0.lat > 1 && $0.lon > 1 })
    }

    /// Fiji: the planet between the sides is no hole, a missing tile is.
    func testAMapAcross180IsCheckedOnEitherSideOfIt() {
        let report = MapCoverage.check(
            [
                tile("a", 0, -180, 1, -179), tile("b", 0, 178, 1, 179), tile("c", 1, 178, 2, 179),
                tile("d", 0, 179, 1, 180)
            ],
            step: 0.25
        )
        XCTAssertEqual(report!.sampled, 16 + 64)
        XCTAssertEqual(report!.holes.count, 16)
        XCTAssertTrue(report!.holes.allSatisfy { $0.lat > 1 && $0.lon > 179 })
        XCTAssertEqual(report!.minLon, 178, "the frame runs from the east side over the seam")
        XCTAssertEqual(report!.maxLon, -179)
    }

    /// The grid is offset by half a step so a sample never lands on a shared edge, where
    /// both neighbours claim it and a gap of nothing between them would read as covered.
    func testASampleNeverLandsOnASharedEdge() {
        // Two tiles a hair apart: 1.0 to 1.001 belongs to neither.
        let report = MapCoverage.check(
            [
                tile("a", 0, 0, 1, 2), tile("b", 1.001, 0, 2, 2)
            ],
            step: 0.5
        )
        // The gap is far thinner than the step, so no sample lands in it.
        XCTAssertTrue(report!.holes.isEmpty)
        // A gap wider than the step is found.
        let wide = MapCoverage.check(
            [
                tile("a", 0, 0, 1, 2), tile("b", 1.6, 0, 2, 2)
            ],
            step: 0.25
        )
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

    /// Every kmap map carries an overview whose box is the whole map's: left in, it covers
    /// every gap between the tiles.
    func testTheOverviewIsLeftOutOfTheTiles() {
        let west = MapCoverage.Tile(name: "63240001", minLat: 44, minLon: 33, maxLat: 45, maxLon: 34)
        let east = MapCoverage.Tile(name: "63240002", minLat: 44, minLon: 35, maxLat: 45, maxLon: 36)
        let overview = MapCoverage.Tile(name: "63240000", minLat: 44, minLon: 33, maxLat: 45, maxLon: 36)
        XCTAssertEqual(MapCoverage.withoutOverview([overview, west, east]).map(\.name), ["63240001", "63240002"])
        XCTAssertEqual(MapCoverage.withoutOverview([west]).map(\.name), ["63240001"])
        // A 1-tile map: the tile and its overview share a box, and the tile stays.
        let alone = MapCoverage.Tile(name: "63240000", minLat: 44, minLon: 33, maxLat: 45, maxLon: 34)
        XCTAssertEqual(MapCoverage.withoutOverview([alone, west]).count, 2)
    }

    /// Fiji's overview runs over the seam and holds both sides.
    func testAnOverviewOverTheSeamIsLeftOut() {
        let west = MapCoverage.Tile(name: "63240001", minLat: -19, minLon: 177, maxLat: -16, maxLon: 180)
        let east = MapCoverage.Tile(name: "63240002", minLat: -19, minLon: -180, maxLat: -16, maxLon: -178)
        let overview = MapCoverage.Tile(name: "63240000", minLat: -19, minLon: 177, maxLat: -16, maxLon: 182)
        XCTAssertEqual(MapCoverage.withoutOverview([overview, west, east]).map(\.name), ["63240001", "63240002"])
    }
}
