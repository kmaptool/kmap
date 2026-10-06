import XCTest

@testable import kmap

/// Contours stop at the water's edge: a lake's surface is level, and a topographic map
/// does not draw a line across it.
final class WaterMaskTests: XCTestCase {
    /// A square ring, corner to corner, closed.
    private func square(
        _ lat: Double,
        _ lon: Double,
        side: Double,
        island: Bool = false,
        standalone: Bool = true,
        group: Int32 = -1
    ) -> WaterBodies.Ring {
        let corners = [(lat, lon), (lat, lon + side), (lat + side, lon + side), (lat + side, lon), (lat, lon)]
        return WaterBodies.Ring(
            points: corners.flatMap { [Float($0.0), Float($0.1)] },
            island: island,
            standalone: standalone,
            group: group
        )
    }

    private func water(_ rings: WaterBodies.Ring...) -> WaterBodies {
        var bodies = WaterBodies()
        for ring in rings { bodies.add(ring) }
        return bodies
    }

    private func line(_ points: (Double, Double)..., closed: Bool = false) -> Contours.Line {
        Contours.Line(elevation: 100, points: points.map { (lat: $0.0, lon: $0.1) }, closed: closed)
    }

    // MARK: The raster

    /// The tracer puts nodes on the cell's own north and east edges: a lake across them
    /// reads wet there, as the neighbour reads it on its south and west edges.
    func testTheNorthAndEastEdgesOfTheCellReadAsTheirLastRowAndColumn() throws {
        let mask = try XCTUnwrap(WaterMask(cellAt: 44, 34, water: water(square(44.9, 34.9, side: 0.2))))
        XCTAssertTrue(mask.isWater(lat: 45, lon: 34.95))
        XCTAssertTrue(mask.isWater(lat: 44.95, lon: 35))
        XCTAssertFalse(mask.isWater(lat: 45.001, lon: 34.95), "past the edge is another cell's")
    }

    func testACellWithoutWaterBuildsNothing() {
        XCTAssertNil(WaterMask(cellAt: 44, 34, water: WaterBodies()))
        XCTAssertNil(
            WaterMask(cellAt: 50, 50, water: water(square(44.4, 34.4, side: 0.1))),
            "the lake is in another cell"
        )
    }

    func testALakeIsWetInsideAndDryOutside() throws {
        let mask = try XCTUnwrap(WaterMask(cellAt: 44, 34, water: water(square(44.4, 34.4, side: 0.1))))
        XCTAssertTrue(mask.isWater(lat: 44.45, lon: 34.45))
        XCTAssertFalse(mask.isWater(lat: 44.39, lon: 34.45))
        XCTAssertFalse(mask.isWater(lat: 44.45, lon: 34.51))
        XCTAssertFalse(mask.isWater(lat: 43.5, lon: 34.45), "outside the cell is never wet")
    }

    func testAnIslandIsDryAndAPondOnItIsWetAgain() throws {
        let lake = square(44.2, 34.2, side: 0.6, standalone: false)
        let island = square(44.4, 34.4, side: 0.2, island: true, standalone: false)
        let pond = square(44.48, 34.48, side: 0.04)
        let mask = try XCTUnwrap(WaterMask(cellAt: 44, 34, water: water(lake, island, pond)))
        XCTAssertTrue(mask.isWater(lat: 44.3, lon: 34.3), "the lake")
        XCTAssertFalse(mask.isWater(lat: 44.42, lon: 34.42), "the island")
        XCTAssertTrue(mask.isWater(lat: 44.5, lon: 34.5), "the pond on the island")
    }

    /// A lake mapped as a multipolygon of its own on another lake's island: the island is
    /// cut out of its own lake only.
    func testAnIslandCutsOnlyItsOwnLake() throws {
        let mask = try XCTUnwrap(
            WaterMask(
                cellAt: 44,
                34,
                water: water(
                    square(44.1, 34.1, side: 0.8, standalone: false, group: 0),
                    square(44.3, 34.3, side: 0.4, island: true, standalone: false, group: 0),
                    square(44.45, 34.45, side: 0.1, standalone: false, group: 1)
                )
            )
        )
        XCTAssertTrue(mask.isWater(lat: 44.2, lon: 34.2), "the big lake")
        XCTAssertFalse(mask.isWater(lat: 44.35, lon: 34.35), "its island")
        XCTAssertTrue(mask.isWater(lat: 44.5, lon: 34.5), "the other lake on the island")
    }

    func testTheOrderTheRingsArriveInDoesNotMatter() throws {
        let lake = square(44.2, 34.2, side: 0.6, standalone: false)
        let island = square(44.4, 34.4, side: 0.2, island: true, standalone: false)
        let mask = try XCTUnwrap(WaterMask(cellAt: 44, 34, water: water(island, lake)))
        XCTAssertFalse(mask.isWater(lat: 44.5, lon: 34.5), "an island is cut out whenever it is listed")
    }

    func testALakeAcrossTwoCellsIsInBoth() throws {
        let bodies = water(square(44.9, 34.9, side: 0.2))
        XCTAssertTrue(try XCTUnwrap(WaterMask(cellAt: 44, 34, water: bodies)).isWater(lat: 44.95, lon: 34.95))
        XCTAssertTrue(try XCTUnwrap(WaterMask(cellAt: 45, 35, water: bodies)).isWater(lat: 45.05, lon: 35.05))
        XCTAssertNotNil(WaterMask(cellAt: 44, 35, water: bodies))
    }

    // MARK: The cut

    func testAContourStopsAtOneShoreAndResumesAtTheOther() throws {
        let mask = try XCTUnwrap(WaterMask(cellAt: 44, 34, water: water(square(44.4, 34.4, side: 0.1))))
        // West to east across the lake: two vertices on each side, two in the water.
        let crossing = line(
            (44.45, 34.30),
            (44.45, 34.38),
            (44.45, 34.42),
            (44.45, 34.48),
            (44.45, 34.52),
            (44.45, 34.60)
        )
        let pieces = mask.clip([crossing])
        XCTAssertEqual(pieces.count, 2)
        let west = try XCTUnwrap(pieces.first), east = try XCTUnwrap(pieces.last)
        // Each piece ends at the shore, not a vertex short of it: within a sixty-fourth of
        // this segment, which is three kilometres long where a real one is thirty metres.
        let step = 0.04 / 64
        XCTAssertEqual(west.points.last?.lon ?? 0, 34.4, accuracy: step + 0.0002)
        XCTAssertEqual(east.points.first?.lon ?? 0, 34.5, accuracy: step + 0.0002)
        XCTAssertLessThanOrEqual(west.points.last?.lon ?? 99, 34.4 + 0.0002, "and on the dry side of it")
        XCTAssertGreaterThanOrEqual(east.points.first?.lon ?? 0, 34.5 - 0.0002)
        XCTAssertEqual(west.points.first?.lon, 34.30)
        XCTAssertEqual(east.points.last?.lon, 34.60)
        XCTAssertTrue(pieces.allSatisfy { $0.elevation == 100 && !$0.closed })
        for piece in pieces {
            for point in piece.points.dropFirst().dropLast() {
                XCTAssertFalse(mask.isWater(lat: point.lat, lon: point.lon))
            }
        }
    }

    func testAContourOverDryGroundIsLeftExactlyAsItWas() throws {
        let mask = try XCTUnwrap(WaterMask(cellAt: 44, 34, water: water(square(44.4, 34.4, side: 0.1))))
        let dry = line((44.1, 34.1), (44.1, 34.2), (44.2, 34.2), (44.1, 34.1), closed: true)
        let pieces = mask.clip([dry])
        XCTAssertEqual(pieces.count, 1)
        XCTAssertEqual(pieces[0].points.count, 4)
        XCTAssertTrue(pieces[0].closed, "a ring that stays dry all the way round stays closed")
    }

    func testAContourWhollyInTheWaterIsNotDrawn() throws {
        let mask = try XCTUnwrap(WaterMask(cellAt: 44, 34, water: water(square(44.4, 34.4, side: 0.1))))
        XCTAssertTrue(mask.clip([line((44.42, 34.42), (44.45, 34.45), (44.48, 34.48))]).isEmpty)
    }

    func testARingCutByTheShoreIsOpenFromThenOn() throws {
        let mask = try XCTUnwrap(WaterMask(cellAt: 44, 34, water: water(square(44.4, 34.4, side: 0.1))))
        let ring = line(
            (44.45, 34.30),
            (44.45, 34.45),
            (44.60, 34.45),
            (44.60, 34.30),
            (44.45, 34.30),
            closed: true
        )
        let pieces = mask.clip([ring])
        XCTAssertFalse(pieces.isEmpty)
        XCTAssertTrue(pieces.allSatisfy { !$0.closed })
    }

    // MARK: What counts as water, and how a shore is joined

    func testLakesReservoirsAndBanksAreWaterAndWetlandIsNot() {
        XCTAssertTrue(WaterBodies.isWater(key: "natural", value: "water"))
        XCTAssertTrue(WaterBodies.isWater(key: "landuse", value: "reservoir"))
        XCTAssertTrue(WaterBodies.isWater(key: "landuse", value: "basin"))
        XCTAssertTrue(WaterBodies.isWater(key: "waterway", value: "riverbank"))
        XCTAssertFalse(WaterBodies.isWater(key: "natural", value: "wetland"), "wetland is ground")
        XCTAssertFalse(WaterBodies.isWater(key: "natural", value: "glacier"), "a glacier keeps its contours")
        XCTAssertFalse(WaterBodies.isWater(key: "waterway", value: "river"), "a line, not an area")
    }

    func testAShoreInPiecesIsJoinedWhicheverWayThePiecesRun() {
        // Three ways, one of them backwards, closing a ring of six nodes.
        let chains = WaterBodies.closedChains(of: [[1, 2, 3], [5, 4, 3], [5, 6, 1]])
        XCTAssertEqual(chains.count, 1)
        XCTAssertEqual(chains[0].first, chains[0].last)
        XCTAssertEqual(Set(chains[0]), [1, 2, 3, 4, 5, 6])
    }

    func testHalfAShoreEnclosesNothing() {
        XCTAssertTrue(WaterBodies.closedChains(of: [[1, 2, 3], [3, 4, 5]]).isEmpty)
    }

    func testTwoLakesOfOneRelationAreTwoRings() {
        let chains = WaterBodies.closedChains(of: [[1, 2, 3, 1], [7, 8], [8, 9, 7]])
        XCTAssertEqual(chains.count, 2)
    }

    // MARK: Pieces left between two shores

    /// Two lakes `gap` degrees apart and a contour across both, one vertex in the gap.
    private func pieces(acrossGap gap: Double) throws -> [Contours.Line] {
        let west = square(44.40, 34.40, side: 0.05)
        let east = square(44.40, 34.45 + gap, side: 0.05)
        let mask = try XCTUnwrap(WaterMask(cellAt: 44, 34, water: water(west, east)))
        return mask.clip([
            line(
                (44.425, 34.30),
                (44.425, 34.42),
                (44.425, 34.45 + gap / 2),
                (44.425, 34.48),
                (44.425, 34.60)
            )
        ])
    }

    func testAScrapBetweenTwoShoresIsDropped() throws {
        // About 24 m of ground.
        let pieces = try pieces(acrossGap: 0.0003)
        XCTAssertEqual(pieces.count, 2, "the line up to the first lake and on from the second")
        XCTAssertEqual(pieces.first?.points.first?.lon, 34.30)
        XCTAssertEqual(pieces.last?.points.last?.lon, 34.60)
    }

    func testAStretchOfGroundBetweenTwoShoresIsKept() throws {
        // About 80 m: a real isthmus.
        XCTAssertEqual(try pieces(acrossGap: 0.001).count, 3)
    }

    func testAShortPieceAtTheEndOfALineIsKept() throws {
        // Its other half may be in the next cell.
        let mask = try XCTUnwrap(WaterMask(cellAt: 44, 34, water: water(square(44.4, 34.4, side: 0.1))))
        let fromTheWest = mask.clip([line((44.45, 34.3999), (44.45, 34.42))])
        XCTAssertEqual(fromTheWest.count, 1, "starts on dry ground, ends at the shore")
        let intoTheEast = mask.clip([line((44.45, 34.48), (44.45, 34.5001))])
        XCTAssertEqual(intoTheEast.count, 1, "starts at the shore, ends on dry ground")
    }

    func testTheThresholdIsTwoRasterCells() {
        XCTAssertEqual(WaterMask.shortestBetweenShores, 2 * 111_320.0 / 7200, accuracy: 1e-9)
        XCTAssertGreaterThan(WaterMask.shortestBetweenShores, 25)
        XCTAssertLessThan(WaterMask.shortestBetweenShores, 35)
    }

    // MARK: The fill against the plain scan

    /// The scanline fill as it was first written: every edge asked about every row.
    private static func plainWet(_ ring: WaterBodies.Ring, side: Int, minLat: Double, minLon: Double) -> Set<Int> {
        var wet = Set<Int>()
        let n = ring.count
        var loLat = Double.infinity, hiLat = -Double.infinity
        for i in 0..<n { loLat = min(loLat, ring.lat(i)); hiLat = max(hiLat, ring.lat(i)) }
        let scale = Double(side)
        let firstRow = max(0, Int(((loLat - minLat) * scale).rounded(.down)))
        let lastRow = min(side - 1, Int(((hiLat - minLat) * scale).rounded(.down)))
        guard firstRow <= lastRow else { return wet }
        for row in firstRow...lastRow {
            let y = minLat + (Double(row) + 0.5) / scale
            var crossings: [Double] = []
            var j = n - 1
            for i in 0..<n {
                let yi = ring.lat(i), yj = ring.lat(j)
                if (yi > y) != (yj > y) {
                    crossings.append((ring.lon(j) - ring.lon(i)) * (y - yi) / (yj - yi) + ring.lon(i))
                }
                j = i
            }
            guard crossings.count >= 2 else { continue }
            crossings.sort()
            var at = 0
            while at + 1 < crossings.count {
                let from = max(0, Int(((crossings[at] - minLon) * scale - 0.5).rounded(.up)))
                let upTo = min(side - 1, Int(((crossings[at + 1] - minLon) * scale - 0.5).rounded(.down)))
                if from <= upTo { for column in from...upTo { wet.insert(row * side + column) } }
                at += 2
            }
        }
        return wet
    }

    func testTheBucketedFillMatchesThePlainScanOnRaggedShores() throws {
        // A jagged shoreline of a few thousand points: the answer at every cell must be
        // the one the plain scan gives.
        var random = SplitMix64(state: 20_260_930)
        let side = WaterMask.cellsPerDegree
        for _ in 0..<2 {
            var points: [Float] = []
            let count = 700
            for k in 0..<count {
                let angle = Double(k) / Double(count) * 2 * Double.pi
                let radius = 0.3 + Double.random(in: -0.05...0.05, using: &random)
                points.append(Float(44.5 + radius * sin(angle)))
                points.append(Float(34.5 + radius * cos(angle)))
            }
            points.append(points[0]); points.append(points[1])
            let ring = WaterBodies.Ring(points: points, island: false, standalone: true)
            let mask = try XCTUnwrap(WaterMask(cellAt: 44, 34, water: water(ring)))
            let wet = Self.plainWet(ring, side: side, minLat: 44, minLon: 34)
            for _ in 0..<8000 {
                let row = Int.random(in: 0..<side, using: &random), column = Int.random(in: 0..<side, using: &random)
                let lat = 44 + (Double(row) + 0.5) / Double(side), lon = 34 + (Double(column) + 0.5) / Double(side)
                XCTAssertEqual(
                    mask.isWater(lat: lat, lon: lon),
                    wet.contains(row * side + column),
                    "row \(row) column \(column)"
                )
            }
        }
    }
}
