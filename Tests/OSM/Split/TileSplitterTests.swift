import XCTest
@testable import kmap

/// Cutting one extract into map tiles.
///
/// The contract is that every tile holds all mkgmap needs to draw and route its own ground,
/// including objects that live mostly elsewhere: a way crossing a border is written whole
/// to both sides.
final class TileSplitterTests: XCTestCase {

    private var directory = URL(fileURLWithPath: "/tmp")

    override func setUpWithError() throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("kmap-splitter-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func path(_ name: String) -> URL { directory.appendingPathComponent(name) }

    // MARK: Units

    func testMapUnitsRoundTheWayTheOldSplitterRounded() {
        // floor(x + 0.5), matching Java's Math.round.
        XCTAssertEqual(TileSplitter.mapUnits(0), 0)
        XCTAssertEqual(TileSplitter.mapUnits(180), 1 << 23)
        XCTAssertEqual(TileSplitter.mapUnits(-180), -(1 << 23))
        XCTAssertEqual(TileSplitter.mapUnits(90), 1 << 22)
        // Halfway between two units rounds up on both sides of zero.
        let unit = 360.0 / Double(1 << 24)
        XCTAssertEqual(TileSplitter.mapUnits(unit * 0.5), 1)
        XCTAssertEqual(TileSplitter.mapUnits(-unit * 0.5), 0)
    }

    func testDegreesAndMapUnitsAgreeWithEachOther() {
        for units in [Int32(0), 1, -1, 1 << 20, -(1 << 20), 1 << 23, -(1 << 23)] {
            XCTAssertEqual(TileSplitter.mapUnits(TileSplitter.degrees(units)), units,
                           "\(units)")
        }
    }

    func testGrainIsTheResolutionThirteenGrid() {
        XCTAssertEqual(TileSplitter.grain, 2048)
    }

    // MARK: Areas

    func testAnAreaIsHalfOpenOnItsTopEdges() {
        let area = TileSplitter.Area(minLat: 0, minLon: 0, maxLat: 2048, maxLon: 2048)
        XCTAssertTrue(area.contains(lat: 0, lon: 0))
        XCTAssertTrue(area.contains(lat: 2047, lon: 2047))
        XCTAssertFalse(area.contains(lat: 2048, lon: 0))
        XCTAssertFalse(area.contains(lat: 0, lon: 2048))
        XCTAssertFalse(area.contains(lat: -1, lon: 0))
    }

    // MARK: Which area holds a point

    /// Four grains to a side, so an interior point stands clear of the delivery band
    /// whatever `shapeClipOverlap` is. Grain-aligned, as a real split's tiles are.
    private static let side = TileSplitter.grain * 4

    private var twoAreas: [TileSplitter.Area] {
        // Side by side, sharing the line at longitude `side`.
        [TileSplitter.Area(minLat: 0, minLon: 0, maxLat: Self.side, maxLon: Self.side),
         TileSplitter.Area(minLat: 0, minLon: Self.side,
                           maxLat: Self.side, maxLon: Self.side * 2)]
    }

    func testAPointInsideAnAreaBelongsToThatOneAlone() {
        let lookup = TileSplitter.AreaLookup(areas: twoAreas)
        let deep = Self.side / 2
        XCTAssertEqual(lookup.areas(lat: deep, lon: deep).sorted, [0])
        XCTAssertEqual(lookup.areas(lat: deep, lon: Self.side + deep).sorted, [1])
    }

    func testAPointOnASharedEdgeBelongsToBothNeighbours() {
        // A way ending exactly on the line is therefore a spanning way.
        let lookup = TileSplitter.AreaLookup(areas: twoAreas)
        XCTAssertEqual(lookup.areas(lat: Self.side / 2, lon: Self.side).sorted, [0, 1])
    }

    func testACornerBelongsToEveryAreaThatTouchesIt() {
        let side = Self.side
        let areas = [
            TileSplitter.Area(minLat: 0, minLon: 0, maxLat: side, maxLon: side),
            TileSplitter.Area(minLat: 0, minLon: side, maxLat: side, maxLon: side * 2),
            TileSplitter.Area(minLat: side, minLon: 0, maxLat: side * 2, maxLon: side),
            TileSplitter.Area(minLat: side, minLon: side, maxLat: side * 2, maxLon: side * 2),
        ]
        let lookup = TileSplitter.AreaLookup(areas: areas)
        XCTAssertEqual(lookup.areas(lat: side, lon: side).sorted, [0, 1, 2, 3])
    }

    func testAPointBeyondEveryAreaBelongsToNone() {
        let lookup = TileSplitter.AreaLookup(areas: twoAreas)
        let clear = TileSplitter.shapeClipOverlap + 1
        XCTAssertEqual(lookup.shapeAreas(lat: Self.side / 2,
                                         lon: Self.side * 2 + clear).count, 0)
        XCTAssertEqual(lookup.shapeAreas(lat: -clear, lon: Self.side / 2).count, 0)
    }

    /// A tile paints `shapeClipOverlap` past its own frame, so a SHAPE within that band of
    /// a neighbour is delivered to the neighbour too. Otherwise the neighbour paints the
    /// band from what it holds and buries the shape.
    func testAShapeJustOutsideAnAreaIsStillDeliveredToIt() {
        let lookup = TileSplitter.AreaLookup(areas: twoAreas)
        let inside = TileSplitter.shapeClipOverlap - 1
        let deep = Self.side / 2
        XCTAssertEqual(lookup.shapeAreas(lat: -inside, lon: deep).sorted, [0])
        // Reaching across the shared line, not merely out of the map.
        XCTAssertEqual(lookup.shapeAreas(lat: deep, lon: Self.side + inside).sorted, [0, 1])
        XCTAssertEqual(lookup.shapeAreas(lat: deep, lon: Self.side - inside).sorted, [0, 1])
    }

    /// The band carries shapes alone. A line is clipped to the frame exactly, because
    /// routing depends on it, so a copy in the band would only duplicate the line.
    func testTheBandDoesNotWidenWhereTheNodeItselfLives() {
        let lookup = TileSplitter.AreaLookup(areas: twoAreas)
        let inside = TileSplitter.shapeClipOverlap - 1
        let deep = Self.side / 2
        XCTAssertEqual(lookup.areas(lat: deep, lon: Self.side + inside).sorted, [1])
        XCTAssertEqual(lookup.areas(lat: deep, lon: Self.side - inside).sorted, [0])
        XCTAssertEqual(lookup.areas(lat: -inside, lon: deep).count, 0)
    }

    /// The band is exactly the overlap: a neighbour further off than that is not given the
    /// shape.
    func testTheBandStopsAtTheOverlap() {
        let lookup = TileSplitter.AreaLookup(areas: twoAreas)
        let clear = TileSplitter.shapeClipOverlap + 1
        let deep = Self.side / 2
        XCTAssertEqual(lookup.shapeAreas(lat: deep, lon: Self.side + clear).sorted, [1])
        XCTAssertEqual(lookup.shapeAreas(lat: deep, lon: Self.side - clear).sorted, [0])
    }

    // MARK: The node table

    func testTheNodeTableGivesBackWhatWasPutIn() {
        let table = TileSplitter.NodeAreas(expecting: 100)
        for id in Int64(1)...100 { table.set(id, UInt16(id % 3)) }
        for id in Int64(1)...100 { XCTAssertEqual(table.get(id), UInt16(id % 3)) }
        XCTAssertNil(table.get(101))
        XCTAssertNil(table.get(0))
    }

    func testTheNodeTableHandlesIDsThatStartOverPartWayThrough() {
        // A second input file ascends from the bottom again.
        let table = TileSplitter.NodeAreas(expecting: 10)
        for id in Int64(100)...110 { table.set(id, 1) }
        for id in Int64(1)...10 { table.set(id, 2) }
        for id in Int64(200)...210 { table.set(id, 3) }
        XCTAssertEqual(table.get(105), 1)
        XCTAssertEqual(table.get(5), 2)
        XCTAssertEqual(table.get(205), 3)
        XCTAssertNil(table.get(50))
    }

    func testAnIDStoredTwiceAnswersWithTheLaterOne() {
        // The same node in the overlap of two extracts: the later value wins.
        let table = TileSplitter.NodeAreas(expecting: 4)
        table.set(7, 1)
        table.set(9, 1)
        table.set(7, 2)          // a new run, and the newer answer
        XCTAssertEqual(table.get(7), 2)
    }

    func testNegativeAndVeryLargeIDsAreHeld() {
        let table = TileSplitter.NodeAreas(expecting: 4)
        let ids: [Int64] = [Int64.min, -1, 0, 1, Int64.max]
        for (index, id) in ids.enumerated() { table.set(id, UInt16(index)) }
        for (index, id) in ids.enumerated() {
            XCTAssertEqual(table.get(id), UInt16(index), "\(id)")
        }
    }

    func testOutsideIsDistinctFromAbsent() {
        let table = TileSplitter.NodeAreas(expecting: 2)
        table.set(1, TileSplitter.NodeAreas.outside)
        XCTAssertEqual(table.get(1), TileSplitter.NodeAreas.outside)
        XCTAssertTrue(table.areas(of: TileSplitter.NodeAreas.outside).isEmpty)
        XCTAssertNil(table.get(2))
    }

    func testANodeOnSeveralAreasKeepsThemAll() {
        let table = TileSplitter.NodeAreas(expecting: 2)
        let value = table.intern([3, 1, 2])
        table.set(1, value)
        XCTAssertEqual(table.areas(of: table.get(1)!), [1, 2, 3])   // sorted, and all there
        // An equal set interns to the same entry.
        XCTAssertEqual(table.intern([2, 3, 1]), value)
        XCTAssertEqual(table.sets.count, 1)
    }

    // MARK: Density and where to cut

    private func density(_ cells: [(lat: Int32, lon: Int32, count: Int)]) -> TileSplitter.Density {
        var density = TileSplitter.Density()
        for cell in cells {
            for _ in 0..<cell.count {
                density.node(id: 1,
                             lat: TileSplitter.degrees(cell.lat << 11) + 0.001,
                             lon: TileSplitter.degrees(cell.lon << 11) + 0.001,
                             tags: [], block: OSMBlock())
            }
        }
        density.seal()
        return density
    }

    // MARK: The table of nodes that must reach further

    /// `absorb` takes sorted stretches that `settle` merges; `note` appends to an unsorted
    /// tail. However it was filled, the result is in id order.
    func testTheExtraTableComesOutInIDOrderHoweverItWasFilled() {
        var extra = TileSplitter.ExtraTiles()
        // The tail: out of order and in no stretch.
        let tail = extra.intern([7])
        for id in [Int64(50), 10, 90, 30] { extra.note(id, set: tail) }
        // Three stretches, each sorted in itself, with overlapping ranges.
        extra.absorb(pool: [[1]], pairs: [(20, 0), (40, 0), (60, 0)], sorted: true)
        extra.absorb(pool: [[2]], pairs: [(15, 0), (35, 0), (95, 0)], sorted: true)
        extra.absorb(pool: [[3]], pairs: [(5, 0), (80, 0)], sorted: true)
        extra.settle()

        let expected: [Int64] = [5, 10, 15, 20, 30, 35, 40, 50, 60, 80, 90, 95]
        var at = 0
        var seen: [Int64] = []
        for id in expected where extra.tiles(for: id, walking: &at) != nil { seen.append(id) }
        XCTAssertEqual(seen, expected, "every id must be found, walking upward once")
    }

    /// A node carried by two ways belongs to both their tiles: the copies are unioned.
    func testANodeCarriedTwiceKeepsBothSetsOfTiles() {
        var extra = TileSplitter.ExtraTiles()
        extra.absorb(pool: [[1, 2]], pairs: [(100, 0)], sorted: true)
        extra.absorb(pool: [[3]], pairs: [(100, 0), (200, 0)], sorted: true)
        extra.settle()
        var at = 0
        XCTAssertEqual(extra.tiles(for: 100, walking: &at), [1, 2, 3])
        XCTAssertEqual(extra.tiles(for: 200, walking: &at), [3])
    }

    /// With an odd number of stretches one has no partner in a merge round and must be
    /// carried forward rather than dropped.
    func testAnOddNumberOfStretchesLosesNothing() {
        var extra = TileSplitter.ExtraTiles()
        var expected: [Int64] = []
        for run in 0..<5 {
            let ids = (0..<7).map { Int64(run + $0 * 5) }
            expected.append(contentsOf: ids)
            extra.absorb(pool: [[UInt16(run)]], pairs: ids.map { ($0, 0) }, sorted: true)
        }
        extra.settle()
        expected.sort()
        var at = 0
        var seen: [Int64] = []
        for id in expected where extra.tiles(for: id, walking: &at) != nil { seen.append(id) }
        XCTAssertEqual(seen, expected)
    }

    func testDensityCountsWhatFallsInARectangle() {
        let d = density([(0, 0, 5), (0, 1, 7), (3, 3, 11)])
        XCTAssertEqual(d.total, 23)
        XCTAssertEqual(d.count(TileSplitter.Density.Cells(minLat: 0, minLon: 0,
                                                          maxLat: 1, maxLon: 2)), 12)
        XCTAssertEqual(d.count(TileSplitter.Density.Cells(minLat: 3, minLon: 3,
                                                          maxLat: 4, maxLon: 4)), 11)
        XCTAssertEqual(d.count(TileSplitter.Density.Cells(minLat: 10, minLon: 10,
                                                          maxLat: 20, maxLon: 20)), 0)
    }

    func testTheBoundsAreTheCellsThatHoldSomething() {
        let d = density([(5, 7, 1), (9, 2, 1)])
        let bounds = d.boundsCells()
        XCTAssertEqual(bounds.minLat, 5)
        XCTAssertEqual(bounds.maxLat, 10)
        XCTAssertEqual(bounds.minLon, 2)
        XCTAssertEqual(bounds.maxLon, 8)
    }

    func testAWideEmptyStretchIsCutThrough() {
        // Two clusters twenty empty cells apart.
        var cells: [(lat: Int32, lon: Int32, count: Int)] = []
        for lon in Int32(0)..<3 { cells.append((0, lon, 100)) }
        for lon in Int32(23)..<26 { cells.append((0, lon, 100)) }
        let d = density(cells)
        let split = d.splitAcrossGap(d.boundsCells())
        XCTAssertNotNil(split)
        XCTAssertEqual(d.count(split!.0), 300)
        XCTAssertEqual(d.count(split!.1), 300)
    }

    func testANarrowGapIsLeftAlone() {
        // A few empty cells are not a divide.
        var cells: [(lat: Int32, lon: Int32, count: Int)] = []
        for lon in Int32(0)..<3 { cells.append((0, lon, 100)) }
        for lon in Int32(8)..<11 { cells.append((0, lon, 100)) }
        let d = density(cells)
        XCTAssertNil(d.splitAcrossGap(d.boundsCells()))
    }

    func testAGapAtTheEdgeIsMarginNotADivide() {
        // Empty cells running off the end of the rectangle are margin: cutting there would
        // leave one side holding nothing.
        var cells: [(lat: Int32, lon: Int32, count: Int)] = []
        for lon in Int32(0)..<3 { cells.append((0, lon, 100)) }
        let d = density(cells)
        let wide = TileSplitter.Density.Cells(minLat: 0, minLon: 0, maxLat: 1, maxLon: 41)
        XCTAssertNil(d.splitAcrossGap(wide))
    }

    func testASplitByShareLandsWhereTheNodesAre() {
        // Ten cells with all the weight in the first two.
        var cells: [(lat: Int32, lon: Int32, count: Int)] = []
        cells.append((0, 0, 500))
        cells.append((0, 1, 500))
        for lon in Int32(2)..<10 { cells.append((0, lon, 1)) }
        let d = density(cells)
        let split = d.split(d.boundsCells(), share: 0.5)
        XCTAssertNotNil(split)
        // The two sides together hold everything, and the lower side holds the weight.
        XCTAssertEqual(d.count(split!.0) + d.count(split!.1), 1008)
        XCTAssertGreaterThan(d.count(split!.0), d.count(split!.1))
    }

    func testASingleCellCannotBeSplit() {
        let d = density([(0, 0, 10)])
        XCTAssertNil(d.split(d.boundsCells(), share: 0.5))
    }

    func testTrimmingShrinksAnAreaOntoTheGroundThatHoldsSomething() {
        let d = density([(5, 5, 1)])
        let wide = TileSplitter.Area(minLat: 0, minLon: 0, maxLat: 10 << 11, maxLon: 10 << 11)
        let tight = d.trim(wide)
        XCTAssertEqual(tight.minLat, 5 << 11)
        XCTAssertEqual(tight.maxLat, 6 << 11)
        XCTAssertEqual(tight.minLon, 5 << 11)
        XCTAssertEqual(tight.maxLon, 6 << 11)
    }
}

// MARK: - The contract, end to end

extension TileSplitterTests {

    /// Multiplier applied to every end-to-end fixture coordinate. The fixtures are written
    /// about a border at 2048 map units; unscaled, that whole span sits inside
    /// `shapeClipOverlap` and every node would land in both tiles.
    private static let fixtureScale: Int32 = 4

    private func scaled(_ units: Int32) -> Int32 { units * Self.fixtureScale }

    private var sideBySide: [TileSplitter.Area] {
        [TileSplitter.Area(minLat: 0, minLon: 0,
                           maxLat: scaled(4096), maxLon: scaled(2048)),
         TileSplitter.Area(minLat: 0, minLon: scaled(2048),
                           maxLat: scaled(4096), maxLon: scaled(4096))]
    }

    private func degrees(_ units: Int32) -> Double { TileSplitter.degrees(units) }

    private struct Tile {
        var nodes: Set<Int64> = []
        var ways: [Int64: [Int64]] = [:]
        var relations: Set<Int64> = []
    }

    private struct TileReader: OSMSink {
        var tile = Tile()
        mutating func node(id: Int64, lat: Double, lon: Double,
                           tags: ArraySlice<Int32>, block: OSMBlock) {
            tile.nodes.insert(id)
        }
        mutating func way(id: Int64, refs: ArraySlice<Int64>, keys: ArraySlice<Int32>,
                          values: ArraySlice<Int32>, block: OSMBlock) {
            tile.ways[id] = Array(refs)
        }
        mutating func relation(id: Int64, memberKinds: ArraySlice<Int32>,
                               memberIDs: ArraySlice<Int64>, memberRoles: ArraySlice<Int32>,
                               keys: ArraySlice<Int32>, values: ArraySlice<Int32>,
                               block: OSMBlock) {
            tile.relations.insert(id)
        }
    }

    private func splitTiles(inputs: [URL], areas: [TileSplitter.Area]) throws -> [Tile] {
        let out = directory.appendingPathComponent("tiles-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let splitter = TileSplitter(options: .init(
            inputs: inputs, outputDirectory: out, mapID: 63410001,
            maxNodes: 1_000_000, description: "test", areas: areas)) { _ in }
        let result = try splitter.run()
        return try result.tiles.map { tile in
            var reader = TileReader()
            try PBFReader(url: out.appendingPathComponent("\(tile.mapID).osm.pbf"))
                .read(into: &reader)
            return reader.tile
        }
    }

    /// Writes an extract with the given objects, placing each node at a longitude in map
    /// units so a test can say which side of the border it is on.
    private func extract(_ name: String,
                         nodes: [(id: Int64, lon: Int32)],
                         ways: [(id: Int64, refs: [Int64])] = [],
                         relations: [PBFWriter.Relation] = []) throws -> URL {
        let url = path(name)
        let writer = try PBFWriter(to: url)
        writer.header(bbox: (minLat: degrees(0), minLon: degrees(0),
                             maxLat: degrees(scaled(4096)), maxLon: degrees(scaled(4096))))
        writer.nodes(nodes.map {
            PBFWriter.Node(id: $0.id, lat: degrees(scaled(1024)),
                           lon: degrees(scaled($0.lon)), tags: [])
        })
        if !ways.isEmpty {
            writer.ways(ways.map { PBFWriter.Way(id: $0.id, refs: $0.refs,
                                                 tags: [("highway", "track")]) })
        }
        if !relations.isEmpty { writer.relations(relations) }
        try writer.finish()
        return url
    }

    func testAnObjectWhollyInsideOneTileGoesToThatTileAlone() throws {
        let input = try extract("one.osm.pbf",
                                nodes: [(1, 100), (2, 200), (3, 3000), (4, 3100)],
                                ways: [(10, [1, 2]), (11, [3, 4])])
        let tiles = try splitTiles(inputs: [input], areas: sideBySide)
        XCTAssertEqual(tiles.count, 2)
        XCTAssertTrue(tiles[0].ways.keys.contains(10))
        XCTAssertFalse(tiles[0].ways.keys.contains(11))
        XCTAssertTrue(tiles[1].ways.keys.contains(11))
        XCTAssertFalse(tiles[1].ways.keys.contains(10))
    }

    /// A closed way lying wholly on one side of the border, but inside the band the
    /// neighbour paints, goes to both tiles. A receiver paints a whole tile at a time, so
    /// draw order across tiles cannot correct for it.
    func testAClosedWayInsideTheNeighboursBandGoesToBothTiles() throws {
        let band = TileSplitter.shapeClipOverlap / Self.fixtureScale
        let justPast = 2048 + band / 2                    // past the line, inside the band
        let input = try extract("band.osm.pbf",
                                nodes: [(1, justPast), (2, justPast + 10),
                                        (3, justPast + 20)],
                                ways: [(10, [1, 2, 3, 1])])
        let tiles = try splitTiles(inputs: [input], areas: sideBySide)
        XCTAssertEqual(tiles[1].ways[10], [1, 2, 3, 1], "the tile it lies in lost it")
        XCTAssertEqual(tiles[0].ways[10], [1, 2, 3, 1],
                       "the neighbour paints this ground and was not given the shape")
        XCTAssertTrue(tiles[0].nodes.isSuperset(of: [1, 2, 3]),
                      "the shape arrived without the nodes that draw it")
    }

    /// The other half of the rule: an open way in the same place is clipped to the frame
    /// exactly and is not copied into the neighbour.
    func testAnOpenWayInsideTheNeighboursBandStaysInItsOwnTile() throws {
        let band = TileSplitter.shapeClipOverlap / Self.fixtureScale
        let justPast = 2048 + band / 2
        let input = try extract("bandline.osm.pbf",
                                nodes: [(1, justPast), (2, justPast + 10)],
                                ways: [(10, [1, 2])])
        let tiles = try splitTiles(inputs: [input], areas: sideBySide)
        XCTAssertEqual(tiles[1].ways[10], [1, 2])
        XCTAssertFalse(tiles[0].ways.keys.contains(10), "a line was carried into the band")
        XCTAssertTrue(tiles[0].nodes.isDisjoint(with: [1, 2]),
                      "a line's nodes were carried into the band")
    }

    func testAWayCrossingTheBorderIsWrittenWholeToBothSides() throws {
        let input = try extract("cross.osm.pbf",
                                nodes: [(1, 100), (2, 1000), (3, 3000), (4, 3900)],
                                ways: [(10, [1, 2, 3, 4])])
        let tiles = try splitTiles(inputs: [input], areas: sideBySide)
        for (index, tile) in tiles.enumerated() {
            XCTAssertEqual(tile.ways[10], [1, 2, 3, 4], "tile \(index) has the way cut short")
            XCTAssertTrue(tile.nodes.isSuperset(of: [1, 2, 3, 4]),
                          "tile \(index) is missing nodes of a way it carries")
        }
    }

    func testAWayEndingExactlyOnTheBorderCountsAsCrossingIt() throws {
        // A node on the shared line belongs to both tiles, so the way spans them.
        let input = try extract("edge.osm.pbf",
                                nodes: [(1, 100), (2, 2048)],
                                ways: [(10, [1, 2])])
        let tiles = try splitTiles(inputs: [input], areas: sideBySide)
        XCTAssertEqual(tiles[0].ways[10], [1, 2])
        XCTAssertEqual(tiles[1].ways[10], [1, 2])
    }

    func testAWayReachingOutOfTheMapKeepsTheNodesThatAreLeft() throws {
        // The far end lies beyond every tile; the tile holding the rest still gets the
        // whole way.
        let input = try extract("fringe.osm.pbf",
                                nodes: [(1, 100), (2, 200), (3, 9000)],
                                ways: [(10, [1, 2, 3])])
        let tiles = try splitTiles(inputs: [input], areas: sideBySide)
        XCTAssertEqual(tiles[0].ways[10], [1, 2, 3])
        XCTAssertTrue(tiles[0].nodes.contains(3))
    }

    func testARelationSpanningTilesIsCarriedToBothWithItsMembers() throws {
        let members = [PBFWriter.Relation.Member(kind: 1, ref: 10, role: "outer"),
                       PBFWriter.Relation.Member(kind: 1, ref: 11, role: "outer")]
        let input = try extract("relation.osm.pbf",
                                nodes: [(1, 100), (2, 200), (3, 3000), (4, 3100)],
                                ways: [(10, [1, 2]), (11, [3, 4])],
                                relations: [PBFWriter.Relation(
                                    id: 20, members: members,
                                    tags: [("type", "multipolygon"), ("natural", "water")])])
        let tiles = try splitTiles(inputs: [input], areas: sideBySide)
        for (index, tile) in tiles.enumerated() {
            XCTAssertTrue(tile.relations.contains(20), "tile \(index) lost the relation")
            // Member ways travel with the relation, or the tile cannot fill it.
            XCTAssertTrue(tile.ways.keys.contains(10), "tile \(index) lost a member way")
            XCTAssertTrue(tile.ways.keys.contains(11), "tile \(index) lost a member way")
        }
    }

    func testARelationOfAKindThatCarriesNothingDoesNotDragItsMembersAround() throws {
        // A route relation fills nothing, so a tile holding none of it carries no member.
        let members = [PBFWriter.Relation.Member(kind: 1, ref: 10, role: "")]
        let input = try extract("route.osm.pbf",
                                nodes: [(1, 100), (2, 200), (3, 3000), (4, 3100)],
                                ways: [(10, [1, 2]), (11, [3, 4])],
                                relations: [PBFWriter.Relation(
                                    id: 20, members: members,
                                    tags: [("type", "route"), ("route", "hiking")])])
        let tiles = try splitTiles(inputs: [input], areas: sideBySide)
        XCTAssertFalse(tiles[1].ways.keys.contains(10))
    }

    func testTheSameObjectInTwoOverlappingExtractsIsWrittenOnce() throws {
        // Adjacent extracts share a margin strip, so the same object arrives twice.
        let first = try extract("a.osm.pbf", nodes: [(1, 100), (2, 200)],
                                ways: [(10, [1, 2])])
        let second = try extract("b.osm.pbf", nodes: [(1, 100), (2, 200), (3, 300)],
                                 ways: [(10, [1, 2]), (11, [2, 3])])
        let out = directory.appendingPathComponent("dedupe")
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let splitter = TileSplitter(options: .init(
            inputs: [first, second], outputDirectory: out, mapID: 63410001,
            maxNodes: 1_000_000, description: "test", areas: sideBySide)) { _ in }
        let result = try splitter.run()

        var counted: [Int64: Int] = [:]
        struct Counter: OSMSink {
            var nodes: [Int64] = []
            var ways: [Int64] = []
            mutating func node(id: Int64, lat: Double, lon: Double,
                               tags: ArraySlice<Int32>, block: OSMBlock) { nodes.append(id) }
            mutating func way(id: Int64, refs: ArraySlice<Int64>, keys: ArraySlice<Int32>,
                              values: ArraySlice<Int32>, block: OSMBlock) { ways.append(id) }
        }
        var wayCounts: [Int64: Int] = [:]
        for tile in result.tiles {
            var reader = Counter()
            try PBFReader(url: out.appendingPathComponent("\(tile.mapID).osm.pbf"))
                .read(into: &reader)
            for id in reader.nodes { counted[id, default: 0] += 1 }
            for id in reader.ways { wayCounts[id, default: 0] += 1 }
        }
        XCTAssertEqual(counted[1], 1)
        XCTAssertEqual(counted[2], 1)
        XCTAssertEqual(counted[3], 1)
        XCTAssertEqual(wayCounts[10], 1)
        XCTAssertEqual(wayCounts[11], 1)
    }

    func testTheCompanionFilesNameEveryTile() throws {
        let input = try extract("list.osm.pbf", nodes: [(1, 100), (2, 3000)])
        let out = directory.appendingPathComponent("companions")
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let splitter = TileSplitter(options: .init(
            inputs: [input], outputDirectory: out, mapID: 63410001,
            maxNodes: 1_000_000, description: "a test map", areas: sideBySide)) { _ in }
        let result = try splitter.run()

        let list = try String(contentsOf: result.areasList, encoding: .utf8)
        XCTAssertTrue(list.contains("63410001: 0,0 to \(scaled(4096)),\(scaled(2048))"), list)
        XCTAssertTrue(list.contains(
            "63410002: 0,\(scaled(2048)) to \(scaled(4096)),\(scaled(4096))"), list)

        let args = try String(contentsOf: result.templateArgs, encoding: .utf8)
        XCTAssertTrue(args.contains("mapname: 63410001"), args)
        XCTAssertTrue(args.contains("input-file: 63410002.osm.pbf"), args)
        XCTAssertTrue(args.contains("description: a test map"), args)
    }

    func testTileNumbersRunOnFromTheOneGiven() throws {
        let input = try extract("ids.osm.pbf", nodes: [(1, 100), (2, 3000)])
        let out = directory.appendingPathComponent("ids")
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let splitter = TileSplitter(options: .init(
            inputs: [input], outputDirectory: out, mapID: 63050001,
            maxNodes: 1_000_000, description: "test", areas: sideBySide)) { _ in }
        let result = try splitter.run()
        XCTAssertEqual(result.tiles.map(\.mapID), ["63050001", "63050002"])
    }

    func testAnExtractWithNoNodesIsRefusedRatherThanSplitIntoNothing() throws {
        let url = path("empty.osm.pbf")
        let writer = try PBFWriter(to: url)
        writer.header()
        try writer.finish()
        let out = directory.appendingPathComponent("none")
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let splitter = TileSplitter(options: .init(
            inputs: [url], outputDirectory: out, mapID: 63410001,
            maxNodes: 1_000_000, description: "test", areas: nil)) { _ in }
        XCTAssertThrowsError(try splitter.run())
    }

    // MARK: Covering the ground without gaps

    /// Writes an extract whose header bbox spans all its nodes. Ground outside the declared
    /// bbox is fringe, covered by no tile, which the shared helper's fixed bbox would leave.
    private func wideExtract(_ name: String, lons: [Int32]) throws -> URL {
        let url = path(name)
        let writer = try PBFWriter(to: url)
        let top = (lons.max() ?? 0) + TileSplitter.grain
        writer.header(bbox: (minLat: degrees(0), minLon: degrees(0),
                             maxLat: degrees(4096), maxLon: degrees(top)))
        writer.nodes(lons.enumerated().map { (i, lon) in
            PBFWriter.Node(id: Int64(i + 1), lat: degrees(1024), lon: degrees(lon), tags: [])
        })
        try writer.finish()
        return url
    }

    /// Returns how many sample points of the covered box belong to no area.
    private func gaps(_ areas: [TileSplitter.Area], step: Int32 = 512) -> Int {
        guard let first = areas.first else { return 0 }
        var minLat = first.minLat, minLon = first.minLon
        var maxLat = first.maxLat, maxLon = first.maxLon
        for a in areas {
            minLat = min(minLat, a.minLat); minLon = min(minLon, a.minLon)
            maxLat = max(maxLat, a.maxLat); maxLon = max(maxLon, a.maxLon)
        }
        var missing = 0
        var lat = minLat
        while lat < maxLat {
            var lon = minLon
            while lon < maxLon {
                if !areas.contains(where: { $0.contains(lat: lat, lon: lon) }) { missing += 1 }
                lon += step
            }
            lat += step
        }
        return missing
    }

    func testTheTilesLeaveNoGroundToNoTile() throws {
        // A tile carries the sea fill and the elevation grid, so ground inside the map's
        // box that belongs to no tile draws blank. Two distant clusters, one node per grid
        // cell, with empty ground between them.
        var lons: [Int32] = []
        for i in 0..<10 { lons.append(Int32(i) * TileSplitter.grain + 8) }
        for i in 30..<40 { lons.append(Int32(i) * TileSplitter.grain + 8) }
        let input = try wideExtract("cover.osm.pbf", lons: lons)
        let out = directory.appendingPathComponent("cover")
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let splitter = TileSplitter(options: .init(
            inputs: [input], outputDirectory: out, mapID: 63410001,
            maxNodes: 3, description: "a test map", areas: nil)) { _ in }
        let areas = try splitter.run().tiles.map(\.area)

        XCTAssertGreaterThan(areas.count, 2, "the split did not divide anything")
        XCTAssertEqual(gaps(areas), 0, "ground inside the map's box belongs to no tile")
    }

    func testNeighbouringTilesMeetRatherThanOverlapOrPartCompany() throws {
        // The tiles are a partition: each inner edge is also a neighbour's edge.
        let input = try wideExtract("meet.osm.pbf",
                                    lons: (0..<24).map { Int32($0) * TileSplitter.grain + 8 })
        let out = directory.appendingPathComponent("meet")
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let splitter = TileSplitter(options: .init(
            inputs: [input], outputDirectory: out, mapID: 63410001,
            maxNodes: 3, description: "a test map", areas: nil)) { _ in }
        let areas = try splitter.run().tiles.map(\.area)

        XCTAssertGreaterThan(areas.count, 3)
        // Every tile's western edge is either the map's own edge or flush with a neighbour.
        let west = areas.map(\.minLon).min()!
        for area in areas where area.minLon != west {
            XCTAssertTrue(areas.contains { $0.maxLon == area.minLon },
                          "a tile starts at \(area.minLon) where none ends")
        }
    }

    // MARK: Cutting only the tile that overflowed

    private func area(_ minLat: Int32, _ minLon: Int32, _ maxLat: Int32, _ maxLon: Int32) -> TileSplitter.Area {
        TileSplitter.Area(minLat: minLat, minLon: minLon, maxLat: maxLat, maxLon: maxLon)
    }

    /// Asserts that two sets of areas cover exactly the same ground, to the grain: neither
    /// a moved boundary nor an opened sliver is allowed.
    private func assertSamePartition(_ before: [TileSplitter.Area], _ after: [TileSplitter.Area],
                                     file: StaticString = #filePath, line: UInt = #line) {
        func cells(_ areas: [TileSplitter.Area]) -> Set<Int64> {
            var out = Set<Int64>()
            for a in areas {
                var lat = a.minLat
                while lat < a.maxLat {
                    var lon = a.minLon
                    while lon < a.maxLon {
                        out.insert(Int64(lat) << 32 | Int64(UInt32(bitPattern: lon)))
                        lon += TileSplitter.grain
                    }
                    lat += TileSplitter.grain
                }
            }
            return out
        }
        XCTAssertEqual(cells(before), cells(after), file: file, line: line)
    }

    func testOnlyTheNamedTileIsCutAndTheGroundStaysWhole() {
        // An overflow cuts the tile that overflowed, not every tile in the map.
        let before = [area(0, 0, 8192, 8192), area(0, 8192, 8192, 16384),
                      area(8192, 0, 16384, 16384)]
        let after = TileSplitter.refined(before, splitting: [1])
        XCTAssertEqual(after.count, 4)
        XCTAssertEqual(after[0].minLat, before[0].minLat)
        XCTAssertEqual(after[0].maxLon, before[0].maxLon)
        XCTAssertEqual(after[3].minLat, before[2].minLat)
        assertSamePartition(before, after)
    }

    func testTheCutFallsOnTheAlignmentGridAlongTheLongerSide() {
        let tall = area(0, 0, 16384, 4096)
        let cut = TileSplitter.refined([tall], splitting: [0])
        XCTAssertEqual(cut.count, 2)
        XCTAssertEqual(cut[0].maxLat, cut[1].minLat)
        XCTAssertEqual(cut[0].maxLat % TileSplitter.grain, 0)
        XCTAssertEqual(cut[0].minLon, cut[1].minLon, "the cut was across the wrong axis")
        assertSamePartition([tall], cut)
    }

    func testATileOneCellWideIsLeftAloneRatherThanCutToNothing() {
        let sliver = area(0, 0, 2048, 2048)
        let out = TileSplitter.refined([sliver], splitting: [0])
        XCTAssertEqual(out.count, 1)
        assertSamePartition([sliver], out)
    }

    func testSeveralOverflowsAreAllCutInOneRound() {
        let before = [area(0, 0, 8192, 8192), area(0, 8192, 8192, 16384),
                      area(8192, 0, 16384, 16384)]
        let after = TileSplitter.refined(before, splitting: [0, 2])
        XCTAssertEqual(after.count, 5)
        assertSamePartition(before, after)
    }

    func testNoOverflowsMeansNoChangeAtAll() {
        let before = [area(0, 0, 8192, 8192), area(0, 8192, 8192, 16384)]
        let after = TileSplitter.refined(before, splitting: [])
        XCTAssertEqual(after.count, 2)
        assertSamePartition(before, after)
    }

    // MARK: The seam nudge

    func testASharedBoundaryOnAPowerOfTwoMoves() {
        // A boundary on a power of two draws a seam on the receiver.
        let round: Int32 = 1 << 21
        let before = [TileSplitter.Area(minLat: 0, minLon: 0, maxLat: round, maxLon: 1000),
                      TileSplitter.Area(minLat: round, minLon: 0, maxLat: round + 100_000, maxLon: 1000)]
        let after = TileSplitter.nudgedOffPowersOfTwo(before)
        XCTAssertEqual(after[0].maxLat, round + TileSplitter.grain)
        XCTAssertEqual(after[1].minLat, round + TileSplitter.grain,
                       "both sides must move together or the split stops partitioning")
        XCTAssertEqual(after[0].minLat, 0, "an outer edge stays put")
        XCTAssertEqual(after[1].maxLat, round + 100_000)
    }

    func testAnOuterEdgeOnAPowerOfTwoStaysPut() {
        // Moving an outer edge inwards would drop the ground beyond it.
        let round: Int32 = 1 << 21
        let before = [TileSplitter.Area(minLat: round, minLon: 0, maxLat: round + 100_000, maxLon: 1000)]
        XCTAssertEqual(TileSplitter.nudgedOffPowersOfTwo(before).first?.minLat, round)
    }

    func testOrdinaryBoundariesAreLeftAlone() {
        // 12 or 13 trailing zeros is where the alignment grid puts a boundary.
        let plain: Int32 = 2_084_864          // lat 44.73633, 12 trailing zeros
        let before = [TileSplitter.Area(minLat: 0, minLon: 0, maxLat: plain, maxLon: 1000),
                      TileSplitter.Area(minLat: plain, minLon: 0, maxLat: plain + 4096, maxLon: 1000)]
        let after = TileSplitter.nudgedOffPowersOfTwo(before)
        XCTAssertEqual(after[0].maxLat, plain)
        XCTAssertEqual(after[1].minLat, plain)
    }
}
