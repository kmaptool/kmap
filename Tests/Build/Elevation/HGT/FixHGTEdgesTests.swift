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
        // All 4 rims zeroed, live ground inside: every one of them gets its neighbour.
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
            at: directory.appendingPathComponent("N44E035.hgt")
        ) { row in
            Int16(200 + row % 30)
        }
        let before = try Data(contentsOf: url)
        XCTAssertNil(try FixHGTEdges.repair(url))
        XCTAssertEqual(try Data(contentsOf: url), before)
    }

    func testAFileThatIsNotAOneArcsecondTileIsLeftAlone() throws {
        let url = directory.appendingPathComponent("N44E036.hgt")
        try FileTools.write(Data([UInt8](repeating: 0, count: 1201 * 1201 * 2)), to: url)
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
        // 3 arc-second tiles are 1201 nodes a side; a size the repairer does not know
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
        try FileTools.write(Data(data), to: url)
        XCTAssertEqual(try FixHGTEdges.repair(url), "south")
        let repaired = [UInt8](try Data(contentsOf: url))
        let last = ((n - 1) * n) * 2
        XCTAssertEqual(repaired[last + 1], 7, "the dead southern row must take its neighbour's value")
    }

    func testADeadEdgeTakesTheCachedNeighboursEdgeSoTheSeamAgrees() throws {
        // The east and south tiles were converted in an earlier pass: their shared edges
        // are what this tile's dead east column and south row become.
        let dead = [Int16](repeating: 0, count: side)
        let url = try write("N44E033.hgt.part") { row in
            guard row < self.side - 1 else { return dead }
            var values = [Int16](repeating: 500, count: self.side)
            values[self.side - 1] = 0
            return values
        }
        _ = try write("N44E034.hgt") { row in
            var values = [Int16](repeating: 900, count: self.side)
            values[0] = Int16(1000 + row % 7)
            return values
        }
        _ = try write("N43E033.hgt") { row in
            [Int16](repeating: row == 0 ? 300 : 200, count: self.side)
        }
        XCTAssertEqual(try FixHGTEdges.repair(url, cell: (44, 33), in: directory), "east,south")
        let sample = try read(url)
        XCTAssertEqual(sample(10, side - 1), 1003)
        XCTAssertEqual(sample(side - 2, side - 1), Int16(1000 + (side - 2) % 7))
        XCTAssertEqual(sample(side - 1, 10), 300)
        XCTAssertEqual(sample(side - 1, side - 1), 300)
        XCTAssertEqual(sample(10, 10), 500)
    }

    func testTheNeighbourAcrossTheAntimeridianIsFound() throws {
        let url = try write("N10E179.hgt.part") { _ in
            var values = [Int16](repeating: 40, count: self.side)
            values[self.side - 1] = 0
            return values
        }
        _ = try write("N10W180.hgt") { _ in
            var values = [Int16](repeating: 0, count: self.side)
            values[0] = 77
            return values
        }
        XCTAssertEqual(try FixHGTEdges.repair(url, cell: (10, 179), in: directory), "east")
        XCTAssertEqual(try read(url)(5, side - 1), 77)
    }

    func testANeighbourOfAnotherSizeIsNotTaken() throws {
        let url = try write("N44E033.hgt.part") { _ in
            var values = [Int16](repeating: 500, count: self.side)
            values[self.side - 1] = 0
            return values
        }
        try FileTools.write(Data(count: 1201 * 1201 * 2), to: directory.appendingPathComponent("N44E034.hgt"))
        XCTAssertEqual(try FixHGTEdges.repair(url, cell: (44, 33), in: directory), "east")
        XCTAssertEqual(try read(url)(5, side - 1), 500)
    }

    /// The west tile landed first, with no data east of it, and copied its inner column
    /// to its east edge. When the east tile lands, that copy takes the east tile's real
    /// edge, so the seam agrees whichever came first.
    func testAnEarlierNeighboursCopiedEdgeTakesTheNewTilesEdge() throws {
        let west = try write("N44E033.hgt") { _ in
            var values = [Int16](repeating: 500, count: self.side)
            values[self.side - 2] = 610
            values[self.side - 1] = 610
            return values
        }
        let east = try write("N44E034.hgt") { row in
            var values = [Int16](repeating: 900, count: self.side)
            values[0] = Int16(700 + row % 5)
            return values
        }
        XCTAssertEqual(FixHGTEdges.refreshNeighbours(of: east, cell: (44, 34), in: directory), ["N44E033.hgt"])
        XCTAssertEqual(try read(west)(9, side - 1), 704)
        XCTAssertEqual(try read(west)(9, side - 2), 610, "only the shared edge")
        // Agreeing now, and asked again, nothing is rewritten.
        XCTAssertEqual(FixHGTEdges.refreshNeighbours(of: east, cell: (44, 34), in: directory), [])
    }

    /// A neighbour whose edge is its own data, not a copy of the line inside it, is kept.
    func testANeighboursRealEdgeIsLeftAlone() throws {
        _ = try write("N44E033.hgt") { _ in
            var values = [Int16](repeating: 500, count: self.side)
            values[self.side - 1] = 650
            return values
        }
        let east = try write("N44E034.hgt") { _ in [Int16](repeating: 900, count: self.side) }
        XCTAssertEqual(FixHGTEdges.refreshNeighbours(of: east, cell: (44, 34), in: directory), [])
    }

    /// 2 tiles landing together: whichever refresh runs first, the seam ends agreeing, and
    /// a tile's own copied edge is never handed on.
    func testTwoTilesLandingTogetherEndWithOneSeam() throws {
        for round in 0..<3 {
            let west = try write("N44E033.hgt") { row in
                var values = [Int16](repeating: 500, count: self.side)
                values[self.side - 2] = Int16(600 + round)
                values[self.side - 1] = Int16(600 + round)
                return values
            }
            let east = try write("N44E034.hgt") { row in
                var values = [Int16](repeating: 900, count: self.side)
                values[0] = Int16(700 + row % 3)
                return values
            }
            DispatchQueue.concurrentPerform(iterations: 2) { which in
                if which == 0 {
                    FixHGTEdges.refreshNeighbours(of: west, cell: (44, 33), in: self.directory)
                } else {
                    FixHGTEdges.refreshNeighbours(of: east, cell: (44, 34), in: self.directory)
                }
            }
            let w = try read(west), e = try read(east)
            for row in [0, 7, 1800, side - 1] {
                XCTAssertEqual(w(row, side - 1), e(row, 0), "round \(round), row \(row)")
            }
            XCTAssertEqual(e(5, 0), Int16(700 + 5 % 3), "the real edge is kept")
        }
    }
}
