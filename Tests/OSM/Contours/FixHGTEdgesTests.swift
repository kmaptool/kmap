import XCTest
@testable import kmap

/// Repairing the dead outer row or column a warped .hgt tile is left with.
///
/// A zeroed last column sits at the same longitude as the next tile's real data, so the
/// ground drops to sea level and back within one grid step, drawing a seam of contours.
final class FixHGTEdgesTests: XCTestCase {

    private var directory = URL(fileURLWithPath: "/tmp")
    private let side = 3601

    override func setUpWithError() throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("kmap-hgt-edges-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    /// Writes a tile row by row; rows that repeat are encoded once.
    private func write(_ name: String, _ row: (Int) -> [Int16]) throws -> URL {
        try HGTFixture.rows(at: directory.appendingPathComponent(name), row)
    }

    private func flat(_ name: String, _ height: Int16) throws -> URL {
        try HGTFixture.constant(height, at: directory.appendingPathComponent(name))
    }

    private func read(_ url: URL) throws -> (Int, Int) -> Int16 {
        let data = try Data(contentsOf: url)
        return { row, column in
            let at = (row * self.side + column) * 2
            return Int16(bitPattern: UInt16(data[at]) << 8 | UInt16(data[at + 1]))
        }
    }

    func testADeadEdgeIsFilledFromTheOneBesideIt() throws {
        // All four rims zeroed, live ground inside: every one of them gets its neighbour.
        let dead = [Int16](repeating: 0, count: side)
        let url = try write("N44E033.hgt") { row in
            guard row > 0, row < self.side - 1 else { return dead }
            var values = [Int16](repeating: Int16(100 + row % 50), count: self.side)
            values[0] = 0
            values[self.side - 1] = 0
            return values
        }
        let filled = try FixHGTEdges.repair(url)
        XCTAssertNotNil(filled)
        for edge in ["east", "west", "north", "south"] {
            XCTAssertTrue(filled?.contains(edge) ?? false, "\(edge) not repaired: \(filled ?? "")")
        }

        let sample = try read(url)
        // Each rim now carries exactly what its neighbour carries.
        XCTAssertEqual(sample(500, side - 1), sample(500, side - 2))
        XCTAssertEqual(sample(500, 0), sample(500, 1))
        XCTAssertEqual(sample(side - 1, 500), sample(side - 2, 500))
        XCTAssertEqual(sample(0, 500), sample(1, 500))
        XCTAssertNotEqual(sample(500, side - 1), 0)
    }

    func testGroundThatIsGenuinelyAtSeaLevelIsLeftAlone() throws {
        // Open sea: the rim is zero and so is its neighbour, so the zero is data.
        let url = try flat("N44E034.hgt", 0)
        XCTAssertNil(try FixHGTEdges.repair(url))
        let sample = try read(url)
        XCTAssertEqual(sample(500, side - 1), 0)
    }

    func testATileThatNeedsNothingIsNotRewritten() throws {
        let url = try HGTFixture.rowConstant(
            at: directory.appendingPathComponent("N44E035.hgt")) { row in
            Int16(200 + row % 30)
        }
        let before = try Data(contentsOf: url)
        XCTAssertNil(try FixHGTEdges.repair(url))
        XCTAssertEqual(try Data(contentsOf: url), before)
    }

    func testAFileThatIsNotAOneArcsecondTileIsLeftAlone() throws {
        let url = directory.appendingPathComponent("N44E036.hgt")
        try Data([UInt8](repeating: 0, count: 1201 * 1201 * 2)).write(to: url)
        XCTAssertNil(try FixHGTEdges.repair(url))
    }

    func testAMissingTileIsAnErrorRatherThanASilentPass() {
        let url = directory.appendingPathComponent("nothing.hgt")
        XCTAssertThrowsError(try FixHGTEdges.repair(url))
    }

    func testOnlyTheDeadEdgeIsTouched() throws {
        // A single dead column, and the rest of the tile must come back untouched.
        var oneRow = [Int16](repeating: 700, count: side)
        oneRow[side - 1] = 0
        let url = try write("N45E033.hgt") { _ in oneRow }
        XCTAssertEqual(try FixHGTEdges.repair(url), "east")
        let sample = try read(url)
        XCTAssertEqual(sample(0, 0), 700)
        XCTAssertEqual(sample(1800, 1800), 700)
        XCTAssertEqual(sample(3600, side - 1), 700)
    }

    func testAThreeArcSecondTileIsRepairedTheSameWay() throws {
        // Three arc-second tiles are 1201 nodes a side; a size the repairer does not know
        // is left untouched.
        let n = 1201
        var data = [UInt8](repeating: 0, count: n * n * 2)
        for row in 0..<n where row < n - 1 {
            for column in 0..<n {
                let at = (row * n + column) * 2
                data[at] = 0; data[at + 1] = 7
            }
        }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("edge-1201-\(UUID().uuidString).hgt")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data(data).write(to: url)
        XCTAssertEqual(try FixHGTEdges.repair(url), "south")
        let repaired = [UInt8](try Data(contentsOf: url))
        let last = ((n - 1) * n) * 2
        XCTAssertEqual(repaired[last + 1], 7, "the dead southern row must take its neighbour's value")
    }

}
