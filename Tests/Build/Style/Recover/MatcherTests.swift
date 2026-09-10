import XCTest
@testable import kmap

/// The matcher against a small ground of its own: what names an element, what refuses.
final class MatcherTests: XCTestCase {

    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("matcher-\(UUID().uuidString.prefix(6))")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: self.folder) }
    }

    // MARK: A ground of a few ways

    private typealias Tags = [(String, String)]

    /// Node `n` sits on a grid a few dozen map units apart, never on one cell with another.
    private func spot(_ n: Int64) -> (lat: Double, lon: Double) {
        (44.5 + Double(n / 100) * 0.001, 34.0 + Double(n % 100) * 0.001)
    }

    private func cell(_ n: Int64) -> UInt64 {
        let at = spot(n)
        return GarminGrid.cell(lat: at.lat, lon: at.lon)
    }

    private func ground(nodes: [Int64], ways: [(id: Int64, refs: [Int64], tags: Tags)],
                        relations: [PBFWriter.Relation] = []) throws -> GroundIndex {
        let url = folder.appendingPathComponent("ground.osm.pbf")
        let writer = try PBFWriter(to: url)
        writer.header()
        writer.nodes(nodes.map {
            PBFWriter.Node(id: $0, lat: spot($0).lat, lon: spot($0).lon, tags: [])
        })
        writer.ways(ways.map { PBFWriter.Way(id: $0.id, refs: $0.refs, tags: $0.tags) })
        writer.relations(relations)
        try writer.finish()
        return try GroundIndex(extract: url,
                               frame: BBox(minLon: 33, minLat: 44, maxLon: 35, maxLat: 45))
    }

    private func named(_ cells: [Int64], in index: GroundIndex, ring: Bool = false) -> Int64? {
        ElementMatcher.way(of: cells.map(cell), in: index, ring: ring)
            .map { index.ways[Int($0)].id }
    }

    // MARK: Short elements

    func testAFiveVertexBuildingNamesItsWay() throws {
        // Two houses sharing a wall.
        let index = try ground(nodes: [1, 2, 3, 4, 5, 6], ways: [
            (10, [1, 2, 3, 4, 1], [("building", "yes")]),
            (11, [3, 4, 5, 6, 3], [("building", "yes")]),
        ])
        XCTAssertEqual(named([1, 2, 3, 4, 1], in: index, ring: true), 10)
        XCTAssertEqual(named([3, 4, 5, 6, 3], in: index, ring: true), 11)
    }

    func testATwoVertexWayIsNamedByItsEdge() throws {
        let index = try ground(nodes: [1, 2, 3], ways: [
            (10, [1, 2], [("highway", "service")]),
            (11, [2, 3], [("highway", "footway")]),
        ])
        XCTAssertEqual(named([1, 2], in: index), 10)
        XCTAssertEqual(named([3, 2], in: index), 11, "written the other way round")
        XCTAssertNil(named([1, 3], in: index), "no such edge")
    }

    // MARK: Neighbours

    func testTwoFieldsSharingAnEdgeAreToldApart() throws {
        // Two farmland polygons with a long common edge 3...10.
        let a: [Int64] = [1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 1]
        let b: [Int64] = [3, 4, 5, 6, 7, 8, 9, 10, 21, 22, 23, 24, 3]
        let index = try ground(nodes: Array(1...24), ways: [
            (10, a, [("landuse", "farmland")]),
            (11, b, [("landuse", "farmland")]),
        ])
        XCTAssertEqual(named(a, in: index, ring: true), 10)
        XCTAssertEqual(named(b, in: index, ring: true), 11)
    }

    func testAPolygonTracedWholeIsNotConfusedByANeighbourOfAnotherKind() throws {
        let wood: [Int64] = [1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 1]
        let field: [Int64] = [3, 4, 5, 6, 7, 8, 9, 10, 21, 22, 23, 24, 3]
        let index = try ground(nodes: Array(1...24), ways: [
            (10, wood, [("natural", "wood")]),
            (11, field, [("landuse", "farmland")]),
        ])
        XCTAssertEqual(named(wood, in: index, ring: true), 10)
        XCTAssertEqual(named(field, in: index, ring: true), 11)
    }

    func testAHoleIsNotWhatTheFillMeans() throws {
        // A forest multipolygon: a bare outer ring, a lake as its inner.
        let outer: [Int64] = [1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 1]
        let lake: [Int64] = [31, 32, 33, 34, 35, 36, 31]
        let forest = PBFWriter.Relation(
            id: 100,
            members: [.init(kind: 1, ref: 10, role: "outer"), .init(kind: 1, ref: 11, role: "inner")],
            tags: [("type", "multipolygon"), ("landuse", "forest")])
        let index = try ground(nodes: Array(1...10) + Array(31...36), ways: [
            (10, outer, []),
            (11, lake, [("natural", "water")]),
        ], relations: [forest])
        // mkgmap cuts the fill through the hole: one piece traces both rings.
        let piece = Array(outer.dropLast()) + lake + [1]
        XCTAssertEqual(named(piece, in: index, ring: true), 10)
        XCTAssertEqual(index.ways.first { $0.id == 10 }?.tags["landuse"], "forest",
                       "lifted from the relation")
        XCTAssertEqual(named(lake, in: index, ring: true), 11, "the lake itself is still the lake")
    }

    // MARK: An older map

    func testAWaySplitSinceTheMapWasMadeIsStillNamed() throws {
        let index = try ground(nodes: Array(1...10), ways: [
            (10, [1, 2, 3, 4, 5], [("highway", "residential")]),
            (11, [5, 6, 7, 8, 9, 10], [("highway", "residential")]),
        ])
        XCTAssertNotNil(named(Array(1...10), in: index))
    }

    func testAWaySplitIntoThingsOfTwoKindsNamesNeither() throws {
        let index = try ground(nodes: Array(1...10), ways: [
            (10, [1, 2, 3, 4, 5], [("highway", "residential")]),
            (11, [5, 6, 7, 8, 9, 10], [("waterway", "stream")]),
        ])
        XCTAssertNil(named(Array(1...10), in: index))
    }

    func testANodeMovedSinceBreaksTheRunNotTheName() throws {
        let index = try ground(nodes: Array(1...15) + [91, 92], ways: [
            (10, Array(1...15), [("highway", "track")]),
        ])
        // Two nodes moved: no run of half the element is left, most of it still aligns.
        var drawn: [Int64] = Array(1...15)
        drawn[5] = 91
        drawn[10] = 92
        XCTAssertEqual(named(drawn, in: index), 10)
    }

    func testARingMayStartAnywhere() throws {
        let index = try ground(nodes: Array(1...6), ways: [
            (10, [1, 2, 3, 4, 5, 6, 1], [("landuse", "grass")]),
        ])
        XCTAssertEqual(named([4, 5, 6, 1, 2, 3, 4], in: index, ring: true), 10)
    }

    // MARK: Zoomed-out points

    /// A village drawn only when zoomed out sits on that level's lattice; the node
    /// standing in the cell names it.
    func testAPointOnAZoomedOutLevelIsNamedByItsCell() throws {
        let url = folder.appendingPathComponent("places.osm.pbf")
        let writer = try PBFWriter(to: url)
        writer.header()
        let at = spot(7)
        writer.nodes([PBFWriter.Node(id: 70, lat: at.lat, lon: at.lon,
                                    tags: [("place", "village"), ("name", "Село")])])
        try writer.finish()
        let index = try GroundIndex(extract: url,
                                    frame: BBox(minLon: 33, minLat: 44, maxLon: 35, maxLat: 45))
        // The point as resolution 22 stores it: snapped to a lattice four units wide.
        var dump = ElementDumper.Dump()
        dump.cells = [GarminGrid.onLattice(cell(7), shift: 2)]
        dump.elements = [ElementDumper.Element(kind: .point, type: 0x0900, from: 0, count: 1)]
        dump.resolutions = [22]
        var evidence = Evidence()
        CoarseEvidence.match(dump, index: index, into: &evidence)
        let code = evidence.codes["P900"]
        XCTAssertEqual(code?.sources[70]?["place"], "village")
        XCTAssertEqual(code?.resolutions[22], 1)
    }

    // MARK: The ground index

    func testABorderSharedByTwoDistrictsIsIndexed() throws {
        let west = PBFWriter.Relation(
            id: 100, members: [.init(kind: 1, ref: 10, role: "outer")],
            tags: [("type", "boundary"), ("boundary", "administrative"), ("admin_level", "6")])
        let east = PBFWriter.Relation(
            id: 101, members: [.init(kind: 1, ref: 10, role: "outer")],
            tags: [("type", "boundary"), ("boundary", "administrative"), ("admin_level", "4")])
        let index = try ground(nodes: Array(1...6), ways: [(10, Array(1...6), [])],
                               relations: [west, east])
        XCTAssertEqual(named(Array(1...6), in: index), 10)
        XCTAssertEqual(index.ways.first?.tags["admin_level"], "4", "the wider boundary")
    }

    func testAWaySharedByAWoodAndABorderIsNobodys() throws {
        let wood = PBFWriter.Relation(
            id: 100, members: [.init(kind: 1, ref: 10, role: "outer")],
            tags: [("type", "multipolygon"), ("landuse", "forest")])
        let border = PBFWriter.Relation(
            id: 101, members: [.init(kind: 1, ref: 10, role: "outer")],
            tags: [("type", "boundary"), ("boundary", "administrative")])
        let index = try ground(nodes: Array(1...6), ways: [(10, Array(1...6), [])],
                               relations: [wood, border])
        XCTAssertTrue(index.ways.isEmpty)
    }

    func testNodesOutOfOrderAreStillFound() throws {
        let index = try ground(nodes: [3, 2, 1], ways: [(10, [1, 2, 3], [("highway", "path")])])
        XCTAssertEqual(named([1, 2, 3], in: index), 10)
    }

    func testANameBeatsADoubt() {
        XCTAssertGreaterThan(Evidence.Match.matched.rawValue, Evidence.Match.ambiguous.rawValue)
        XCTAssertGreaterThan(Evidence.Match.ambiguous.rawValue, Evidence.Match.unmatched.rawValue)
    }
}
