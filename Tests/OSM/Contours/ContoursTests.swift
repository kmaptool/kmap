import XCTest
@testable import kmap

/// Tracing contour lines across a .hgt tile by marching squares. A contour separates ground
/// above the level from ground below, so every line closes or leaves the tile, and none cross.
final class ContoursTests: XCTestCase {

    /// A grid given row by row, north edge first, as a .hgt stores it.
    private func grid(_ rows: [[Int]], lat: Int = 44, lon: Int = 33) -> Contours.Grid {
        let n = rows.count
        var samples: [Int16] = []
        samples.reserveCapacity(n * n)
        for row in rows {
            XCTAssertEqual(row.count, n, "the grid must be square")
            samples.append(contentsOf: row.map { Int16($0) })
        }
        return Contours.Grid(samples: samples, n: n, lat: lat, lon: lon)
    }

    private func trace(_ rows: [[Int]], step: Int = 10,
                       clip: (minLat: Double, minLon: Double,
                              maxLat: Double, maxLon: Double)? = nil) -> [Contours.Line] {
        var tracer = Contours(grid: grid(rows), step: step)
        tracer.clip = clip
        return tracer.trace()
    }

    // MARK: The grid itself

    func testRowZeroIsTheNorthEdge() {
        let g = grid([[0, 0], [0, 0]])
        XCTAssertEqual(g.latitude(0), 45)          // the top row of tile N44
        XCTAssertEqual(g.latitude(1), 44)
        XCTAssertEqual(g.longitude(0), 33)
        XCTAssertEqual(g.longitude(1), 34)
    }

    func testFlatGroundHasNoContours() {
        XCTAssertTrue(trace([[10, 10], [10, 10]]).isEmpty)
        XCTAssertTrue(trace([[7, 7, 7], [7, 7, 7], [7, 7, 7]]).isEmpty)
    }

    func testASlopeCrossingOneLevelGivesOneLine() {
        // Ground rising from 5 to 15 across the cell: the 10 m contour runs through it.
        let lines = trace([[5, 15], [5, 15]])
        XCTAssertEqual(lines.count, 1)
        XCTAssertEqual(lines[0].elevation, 10)
        XCTAssertEqual(lines[0].points.count, 2)
    }

    func testALevelIsCrossedWhereTheSampleSitsExactlyOnIt() {
        // A sample sitting exactly on the level counts as crossing it.
        let lines = trace([[0, 1], [0, 1]], step: 10)
        XCTAssertEqual(lines.count, 1)
        XCTAssertEqual(lines[0].elevation, 0)
    }

    func testEveryLevelTheGroundReachesIsTraced() {
        // 0 to 45 across the grid with a step of 10: levels 0, 10, 20, 30 and 40.
        let lines = trace([[0, 15, 45], [0, 15, 45], [0, 15, 45]], step: 10)
        XCTAssertEqual(Set(lines.map(\.elevation)), [0, 10, 20, 30, 40])
    }

    func testNoLevelIsTracedOutsideTheGroundsOwnRange() {
        let lines = trace([[12, 18], [12, 18]], step: 10)
        XCTAssertEqual(Set(lines.map(\.elevation)), [])   // nothing between 12 and 18
        let crossing = trace([[8, 18], [8, 18]], step: 10)
        XCTAssertEqual(Set(crossing.map(\.elevation)), [10])
    }

    func testAHillGivesAClosedRing() {
        let lines = trace([
            [0, 0, 0, 0, 0],
            [0, 5, 5, 5, 0],
            [0, 5, 30, 5, 0],
            [0, 5, 5, 5, 0],
            [0, 0, 0, 0, 0],
        ], step: 10)
        XCTAssertFalse(lines.isEmpty)
        for line in lines {
            XCTAssertTrue(line.closed, "a ring inside the tile must close")
            XCTAssertEqual(line.points.first?.lat, line.points.last?.lat)
            XCTAssertEqual(line.points.first?.lon, line.points.last?.lon)
        }
    }

    func testALineLeavingTheTileIsOpen() {
        // Two of them here: 0 m along the western samples and 10 m through the slope.
        // Neither can close, since both run off the northern and southern edges.
        let lines = trace([[0, 20], [0, 20]], step: 10)
        XCTAssertEqual(Set(lines.map(\.elevation)), [0, 10])
        XCTAssertTrue(lines.allSatisfy { !$0.closed })
    }

    // MARK: Voids

    func testACellWithAVoidIsNotTraced() {
        // Interpolating between real ground and nodata invents a cliff.
        let lines = trace([[0, 20], [-32768, 20]], step: 10)
        XCTAssertTrue(lines.isEmpty)
    }

    func testGroundBesideAVoidIsStillTraced() {
        let lines = trace([
            [-32768, -32768, -32768],
            [-32768, 0, 20],
            [-32768, 0, 20],
        ], step: 10)
        // The 0 m line runs along the samples that sit exactly on it, and the 10 m line
        // through the slope; 20 does not cross, since nothing is above it.
        XCTAssertEqual(Set(lines.map(\.elevation)), [0, 10])
    }

    // MARK: Saddles

    func testASaddleIsolatesTheLowCornersBelowTheMiddleAndTheHighOnesAbove() {
        // Which pair of corners the arcs cut off is decided by the cell's mean, as in
        // contourpy.
        let saddle = [[10, 0], [0, 10]]
        for (level, step) in [(4, 4), (6, 6)] {
            let lines = trace(saddle, step: step).filter { $0.elevation == level }
            XCTAssertEqual(lines.count, 2, "level \(level)")
        }
        // Exactly halfway behaves as the upper case does.
        XCTAssertEqual(trace(saddle, step: 5).filter { $0.elevation == 5 }.count, 2)
    }

    /// The densest arrangement of saddles, filling every crossing's second link slot. The
    /// tracer keeps two slots per crossing and asserts that bound.
    func testEveryCellASaddleStillJoinsEachCrossingAtMostTwice() {
        // A checkerboard: every 2x2 window has the high pair on one diagonal and the low
        // pair on the other, so every cell of the grid is a saddle at level 5.
        var rows: [[Int]] = []
        for row in 0..<9 {
            rows.append((0..<9).map { column in (row + column) % 2 == 0 ? 10 : 0 })
        }
        let lines = trace(rows, step: 5).filter { $0.elevation == 5 }
        XCTAssertFalse(lines.isEmpty)
        for line in lines {
            XCTAssertGreaterThanOrEqual(line.points.count, 2)
        }
    }

    // MARK: The order lines come out in

    /// Output order fixes every node id in the file: loose ends before rings, each in
    /// ascending order of the edge the walk starts from, north to south and west to east.
    func testLooseEndsAreWalkedBeforeRings() {
        // A peak in the north giving a closed ring, and a wall along the south edge
        // giving a line that leaves the tile on both sides. Both at level 10.
        var rows = [[Int]](repeating: [Int](repeating: 0, count: 5), count: 5)
        rows[1][3] = 20
        rows[4] = [20, 20, 20, 20, 20]
        let lines = trace(rows, step: 10).filter { $0.elevation == 10 }
        XCTAssertEqual(lines.count, 2)
        XCTAssertFalse(lines[0].closed, "the open line comes first")
        XCTAssertTrue(lines[1].closed)
    }

    func testTwoRingsComeOutWestToEast() {
        var rows = [[Int]](repeating: [Int](repeating: 0, count: 7), count: 7)
        rows[3][1] = 20
        rows[3][5] = 20
        let lines = trace(rows, step: 10).filter { $0.elevation == 10 }
        XCTAssertEqual(lines.count, 2)
        XCTAssertTrue(lines[0].closed)
        XCTAssertTrue(lines[1].closed)
        let west = lines[0].points.map(\.lon).max() ?? 0
        let east = lines[1].points.map(\.lon).min() ?? 0
        XCTAssertLessThan(west, east, "the western ring is written first")
    }

    // MARK: Clipping

    func testGroundOutsideTheClipIsNotTraced() {
        let rows = [[0, 0, 20], [0, 0, 20], [0, 0, 20]]
        let whole = trace(rows, step: 10)
        XCTAssertFalse(whole.isEmpty)
        // A box over the flat western half only.
        let clipped = trace(rows, step: 10,
                            clip: (minLat: 44.0, minLon: 33.0, maxLat: 45.0, maxLon: 33.4))
        XCTAssertTrue(clipped.isEmpty)
    }

    func testAClipCoveringEverythingChangesNothing() {
        let rows = [[0, 10, 20], [0, 10, 20], [0, 10, 20]]
        let whole = trace(rows, step: 10)
        let clipped = trace(rows, step: 10,
                            clip: (minLat: 44.0, minLon: 33.0, maxLat: 45.0, maxLon: 34.0))
        XCTAssertEqual(whole.count, clipped.count)
        XCTAssertEqual(whole.map(\.elevation).sorted(), clipped.map(\.elevation).sorted())
        for (a, b) in zip(whole, clipped) {
            XCTAssertEqual(a.points.count, b.points.count)
        }
    }

    func testAClipOutsideTheTileTracesNothing() {
        let lines = trace([[0, 20], [0, 20]], step: 10,
                          clip: (minLat: 10, minLon: 10, maxLat: 11, maxLon: 11))
        XCTAssertTrue(lines.isEmpty)
    }

    // MARK: Long lines

    func testALineLongerThanTheLimitIsCutAndTheHalvesStillJoin() {
        // The pieces share the vertex they are cut at, or the contour breaks on the map.
        var points: [(lat: Double, lon: Double)] = []
        for i in 0..<(Contours.maxPoints * 2 + 5) {
            points.append((lat: 44 + Double(i) * 1e-6, lon: 33))
        }
        let line = Contours.Line(elevation: 100, points: points, closed: false)
        let pieces = Contours.split([line])
        XCTAssertGreaterThan(pieces.count, 1)
        XCTAssertEqual(pieces.reduce(0) { $0 + $1.points.count } - (pieces.count - 1),
                       points.count)
        for i in 1..<pieces.count {
            XCTAssertEqual(pieces[i - 1].points.last?.lat, pieces[i].points.first?.lat)
            XCTAssertEqual(pieces[i - 1].points.last?.lon, pieces[i].points.first?.lon)
        }
        XCTAssertTrue(pieces.allSatisfy { $0.points.count <= Contours.maxPoints })
    }

    func testAShortLineIsLeftWhole() {
        let line = Contours.Line(elevation: 100,
                                 points: [(44, 33), (44.1, 33.1)], closed: false)
        XCTAssertEqual(Contours.split([line]).count, 1)
    }

    // MARK: What the lines look like

    func testEveryPointOfEveryLineIsInsideTheTile() {
        let lines = trace([
            [0, 10, 20, 30],
            [5, 15, 25, 35],
            [10, 20, 30, 40],
            [15, 25, 35, 45],
        ], step: 10)
        XCTAssertFalse(lines.isEmpty)
        for line in lines {
            for point in line.points {
                XCTAssertGreaterThanOrEqual(point.lat, 44)
                XCTAssertLessThanOrEqual(point.lat, 45)
                XCTAssertGreaterThanOrEqual(point.lon, 33)
                XCTAssertLessThanOrEqual(point.lon, 34)
            }
        }
    }

    func testNoLineRepeatsAPointItJustPassed() {
        // A crossing landing exactly on a grid node belongs to both edges meeting there,
        // so the same position can arrive twice in a row.
        let lines = trace([
            [0, 10, 20],
            [10, 20, 30],
            [20, 30, 40],
        ], step: 10)
        for line in lines {
            for i in 1..<line.points.count {
                XCTAssertFalse(line.points[i].lat == line.points[i - 1].lat
                               && line.points[i].lon == line.points[i - 1].lon,
                               "a point repeats at \(line.elevation) m")
            }
        }
    }

    func testEveryLineHasAtLeastTwoPoints() {
        let lines = trace([
            [0, 10, 20],
            [10, 20, 30],
            [20, 30, 40],
        ], step: 10)
        for line in lines {
            XCTAssertGreaterThanOrEqual(line.points.count, 2)
        }
    }
}
