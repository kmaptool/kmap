import XCTest

@testable import kmap

/// The ground, read off the .hgt tiles the contour step downloads. Posts are 30 m apart.
///
/// Reads the nearest post, answers nil where the data is absent, and treats the -32768
/// void marker as no answer rather than as a height.
final class TerrainTests: XCTestCase {
    private var directory = URL(fileURLWithPath: "/tmp")
    private let size = 3601

    override func setUpWithError() throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("kmap-terrain-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    /// Writes one .hgt tile whose height varies only from north to south. Row 0 is the
    /// tile's northern edge.
    private func writeRows(_ name: String, _ height: (Int) -> Int16) throws {
        try HGTFixture.rowConstant(at: directory.appendingPathComponent(name), height)
    }

    /// Ground that varies only from west to east: one row, repeated.
    private func writeColumns(_ name: String, _ height: (Int) -> Int16) throws {
        let row = (0..<size).map(height)
        try HGTFixture.rows(at: directory.appendingPathComponent(name)) { _ in row }
    }

    private func writeFlat(_ name: String, _ height: Int16) throws {
        try HGTFixture.constant(height, at: directory.appendingPathComponent(name))
    }

    func testAHeightComesBackFromThePostNearestThePoint() throws {
        // Height is the row number, so the answer names the post that was read.
        try writeRows("N44E033.hgt") { row in Int16(row % 30000) }
        let terrain = Terrain(directory: directory)
        // The top row is the northern edge, at 45°N.
        XCTAssertEqual(terrain.elevation(45.0, 33.5) ?? -1, 0, accuracy: 0.5)
        // The bottom row is 44°N.
        XCTAssertEqual(terrain.elevation(44.0, 33.5) ?? -1, Double(size - 1), accuracy: 0.5)
        // Halfway down.
        XCTAssertEqual(
            terrain.elevation(44.5, 33.5) ?? -1,
            Double(size - 1) / 2,
            accuracy: 1
        )
    }

    func testEachTileIsReadFromTheFirstDirectoryHoldingIt() throws {
        // The DEM layer's order: the chosen source first, the next only for its gaps.
        let first = directory.appendingPathComponent("first")
        let second = directory.appendingPathComponent("second")
        for dir in [first, second] {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        try HGTFixture.constant(100, at: first.appendingPathComponent("N44E033.hgt"))
        try HGTFixture.constant(200, at: second.appendingPathComponent("N44E033.hgt"))
        try HGTFixture.constant(300, at: second.appendingPathComponent("N45E033.hgt"))
        let terrain = Terrain(directories: [first, second])
        XCTAssertEqual(terrain.elevation(44.5, 33.5), 100)
        XCTAssertEqual(terrain.elevation(45.5, 33.5), 300)
        XCTAssertNil(terrain.elevation(46.5, 33.5))
    }

    /// A 3 arc-second tile, 1201 posts a side, with a height per row: row r holds r.
    private func writeCoarse(_ url: URL) throws {
        let side = 1201
        var bytes = [UInt8](repeating: 0, count: side * side * 2)
        for row in 0..<side {
            for column in 0..<side {
                bytes[(row * side + column) * 2] = UInt8(row >> 8)
                bytes[(row * side + column) * 2 + 1] = UInt8(row & 0xFF)
            }
        }
        try FileTools.write(Data(bytes), to: url)
    }

    /// The elevation directories hold tiles of either grid; one of 1201 posts is read by
    /// its own grid, all the way to its southern edge.
    func testA3ArcSecondTileIsReadByItsOwnGrid() throws {
        try writeCoarse(directory.appendingPathComponent("N44E033.hgt"))
        let terrain = Terrain(directory: directory)
        XCTAssertEqual(terrain.elevation(45.0, 33.5), 0, "the northern edge is row 0")
        XCTAssertEqual(terrain.elevation(44.5, 33.5), 600, "halfway down is row 600 of 1200")
        XCTAssertEqual(terrain.elevation(44.0, 33.5), 1200, "the southern edge is the last row")
    }

    /// The slope across a coarse tile is taken a post of that tile away: 1 m a row over
    /// 3 arc-seconds, 92.7 m, is 0.62 degrees, not the 1.85 a 1 arc-second step would give.
    func testTheSlopeOfACoarseTileStepsByItsOwnPosts() throws {
        try writeCoarse(directory.appendingPathComponent("N44E033.hgt"))
        let terrain = Terrain(directory: directory)
        let slope = try XCTUnwrap(terrain.slope(44.5, 33.5))
        XCTAssertEqual(slope, atan(1 / 92.7) * 180 / .pi, accuracy: 0.01)
    }

    func testColumnsRunEastFromTheTilesWesternEdge() throws {
        try writeColumns("N44E033.hgt") { column in Int16(column % 30000) }
        let terrain = Terrain(directory: directory)
        XCTAssertEqual(terrain.elevation(44.5, 33.0) ?? -1, 0, accuracy: 0.5)
        XCTAssertEqual(terrain.elevation(44.5, 34.0) ?? -1, Double(size - 1), accuracy: 0.5)
    }

    func testAVoidIsNoAnswerRatherThanSeaLevel() throws {
        // -32768 marks a hole in the survey.
        try writeFlat("N44E033.hgt", -32768)
        XCTAssertNil(Terrain(directory: directory).elevation(44.5, 33.5))
    }

    func testGroundThatIsSimplyMissingIsNoAnswerEither() {
        XCTAssertNil(Terrain(directory: directory).elevation(10.5, 20.5))
        XCTAssertNil(Terrain(directory: directory).slope(10.5, 20.5))
    }

    func testTilesSouthAndWestAreNamedAsSuch() throws {
        try writeFlat("S34W071.hgt", 500)
        let terrain = Terrain(directory: directory)
        XCTAssertEqual(terrain.elevation(-33.5, -70.5) ?? 0, 500, accuracy: 0.5)
    }

    func testFlatGroundHasNoSlope() throws {
        try writeFlat("N44E033.hgt", 100)
        XCTAssertEqual(
            Terrain(directory: directory).slope(44.5, 33.5) ?? -1,
            0,
            accuracy: 0.01
        )
    }

    func testAStepOfOnePostHeightIsAboutFortyFiveDegrees() throws {
        // One post is 30.9 m of latitude, so a 30.9 m rise across it is 45°.
        try writeRows("N44E033.hgt") { row in
            Double(row) * 30.9 < 30000 ? Int16(Double(row) * 30.9) : 0
        }
        let slope = Terrain(directory: directory).slope(44.9, 33.5)
        XCTAssertNotNil(slope)
        XCTAssertEqual(slope ?? 0, 45, accuracy: 2)
    }

    func testAPointOnTheTileEdgeStaysInsideTheFile() throws {
        try writeFlat("N44E033.hgt", 42)
        let terrain = Terrain(directory: directory)
        for (lat, lon) in [(44.0, 33.0), (45.0, 34.0), (44.0, 34.0), (45.0, 33.0)] {
            XCTAssertEqual(
                terrain.elevation(lat, lon) ?? 0,
                42,
                accuracy: 0.5,
                "\(lat),\(lon)"
            )
        }
    }

    func testATruncatedTileDoesNotReadPastItsEnd() throws {
        // A half-written file: the reader must not run past its end.
        let short = Data([UInt8](repeating: 0, count: 1000))
        try FileTools.write(short, to: directory.appendingPathComponent("N44E033.hgt"))
        let terrain = Terrain(directory: directory)
        XCTAssertNil(terrain.elevation(44.5, 33.5))
        XCTAssertNotNil(terrain.elevation(45.0, 33.0))  // the first post is there
    }

    func testTheSameTileIsOnlyReadOnce() throws {
        // Tiles are cached: the answer survives the file being removed.
        try writeFlat("N44E033.hgt", 7)
        let terrain = Terrain(directory: directory)
        XCTAssertEqual(terrain.elevation(44.5, 33.5) ?? 0, 7, accuracy: 0.5)
        try FileManager.default.removeItem(at: directory.appendingPathComponent("N44E033.hgt"))
        XCTAssertEqual(terrain.elevation(44.6, 33.6) ?? 0, 7, accuracy: 0.5)
    }
}
