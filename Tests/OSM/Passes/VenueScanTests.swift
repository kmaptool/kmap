import XCTest
@testable import kmap

/// Finding the areas that merely repeat a venue already on the map: a site and the
/// building standing in it both carrying the same tag.
///
/// A style rule sees one object at a time, so the geometry is compared here instead.
final class VenueScanTests: XCTestCase {

    private var directory = URL(fileURLWithPath: "/tmp")

    override func setUpWithError() throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("kmap-venues-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    // MARK: Point in ring

    private let square: [(x: Double, y: Double)] = [(0, 0), (10, 0), (10, 10), (0, 10), (0, 0)]

    func testAPointInsideAndOutsideARing() {
        XCTAssertTrue(VenueScan.inside((5, 5), square))
        XCTAssertFalse(VenueScan.inside((15, 5), square))
        XCTAssertFalse(VenueScan.inside((-1, 5), square))
        XCTAssertFalse(VenueScan.inside((5, 15), square))
    }

    func testAConcaveRingIsNotFooledByItsBoundingBox() {
        // An L: the corner cut out of the bounding box is outside the shape.
        let ell: [(x: Double, y: Double)] = [(0, 0), (10, 0), (10, 4), (4, 4), (4, 10),
                                             (0, 10), (0, 0)]
        XCTAssertTrue(VenueScan.inside((2, 2), ell))
        XCTAssertTrue(VenueScan.inside((8, 2), ell))
        XCTAssertFalse(VenueScan.inside((8, 8), ell))
    }

    // MARK: Marking

    private func area(_ id: Int64, _ box: (Double, Double, Double, Double),
                      tag: String = "amenity=cafe", named: Bool = false,
                      seen: Int = 0) -> VenueScan.Area {
        let ring: [(x: Double, y: Double)] = [(box.0, box.1), (box.2, box.1),
                                              (box.2, box.3), (box.0, box.3), (box.0, box.1)]
        return VenueScan.Area(id: id, seen: seen, tag: tag, ring: ring,
                              box: (box.0, box.1, box.2, box.3),
                              size: (box.2 - box.0) * (box.3 - box.1), named: named)
    }

    func testTheInnerOfTwoAreasSayingTheSameThingIsMarked() {
        // The outer area carries the name and the inner one is anonymous.
        let marked = VenueScan.mark([area(1, (0, 0, 10, 10), named: true),
                                     area(2, (2, 2, 4, 4), seen: 1)], nodes: [])
        XCTAssertEqual(marked, [2])
    }

    func testTheNamedOneSurvivesWhereTheNamingRunsTheOtherWay() {
        // A named inner area inside a larger unnamed one: the inner one is kept.
        let marked = VenueScan.mark([area(1, (0, 0, 10, 10), named: false),
                                     area(2, (2, 2, 4, 4), named: true, seen: 1)], nodes: [])
        XCTAssertEqual(marked, [1])
    }

    func testAreasSayingDifferentThingsAreBothKept() {
        let marked = VenueScan.mark([area(1, (0, 0, 10, 10), tag: "amenity=cafe"),
                                     area(2, (2, 2, 4, 4), tag: "shop=bakery", seen: 1)],
                                    nodes: [])
        XCTAssertTrue(marked.isEmpty)
    }

    func testTwoAreasSideBySideAreBothKept() {
        let marked = VenueScan.mark([area(1, (0, 0, 4, 4)),
                                     area(2, (6, 6, 10, 10), seen: 1)], nodes: [])
        XCTAssertTrue(marked.isEmpty)
    }

    func testAnAreaOverlappingWithoutEnclosingIsKept() {
        let marked = VenueScan.mark([area(1, (0, 0, 10, 10)),
                                     area(2, (8, 8, 14, 14), seen: 1)], nodes: [])
        XCTAssertTrue(marked.isEmpty)
    }

    func testAnAreaDrawnRoundAPOINodeThatAlreadySaysSoIsMarked() {
        // The area's own point repeats the node already inside it.
        let marked = VenueScan.mark([area(1, (0, 0, 10, 10))],
                                    nodes: [(tag: "amenity=cafe", x: 5, y: 5)])
        XCTAssertEqual(marked, [1])
    }

    func testANodeOutsideTheAreaOrSayingSomethingElseChangesNothing() {
        XCTAssertTrue(VenueScan.mark([area(1, (0, 0, 10, 10))],
                                     nodes: [(tag: "amenity=cafe", x: 50, y: 50)]).isEmpty)
        XCTAssertTrue(VenueScan.mark([area(1, (0, 0, 10, 10))],
                                     nodes: [(tag: "shop=bakery", x: 5, y: 5)]).isEmpty)
    }

    func testThreeNestedAreasLeaveOnlyTheOutermost() {
        let marked = VenueScan.mark([area(1, (0, 0, 10, 10)),
                                     area(2, (2, 2, 8, 8), seen: 1),
                                     area(3, (3, 3, 5, 5), seen: 2)], nodes: [])
        XCTAssertEqual(marked, [2, 3])
    }

    func testTwoAreasOfTheSameSizeAreOrderedByWhereTheyStoodInTheFile() {
        // The sort is not stable, so equal sizes are ordered by file position.
        let first = VenueScan.mark([area(1, (0, 0, 10, 10), seen: 0),
                                    area(2, (0, 0, 10, 10), seen: 1)], nodes: [])
        for _ in 0..<5 {
            XCTAssertEqual(VenueScan.mark([area(1, (0, 0, 10, 10), seen: 0),
                                           area(2, (0, 0, 10, 10), seen: 1)], nodes: []),
                           first)
        }
    }

    // MARK: A whole extract

    func testABuildingInsideItsOwnSiteIsFoundInAFile() throws {
        let url = directory.appendingPathComponent("in.osm.pbf")
        let writer = try PBFWriter(to: url)
        writer.header()
        // Four corners of the outer ring, four of the ring inside it.
        writer.nodes([
            PBFWriter.Node(id: 1, lat: 44.0, lon: 33.0, tags: []),
            PBFWriter.Node(id: 2, lat: 44.0, lon: 33.01, tags: []),
            PBFWriter.Node(id: 3, lat: 44.01, lon: 33.01, tags: []),
            PBFWriter.Node(id: 4, lat: 44.01, lon: 33.0, tags: []),
            PBFWriter.Node(id: 5, lat: 44.002, lon: 33.002, tags: []),
            PBFWriter.Node(id: 6, lat: 44.002, lon: 33.004, tags: []),
            PBFWriter.Node(id: 7, lat: 44.004, lon: 33.004, tags: []),
            PBFWriter.Node(id: 8, lat: 44.004, lon: 33.002, tags: []),
        ])
        writer.ways([
            PBFWriter.Way(id: 100, refs: [1, 2, 3, 4, 1],
                          tags: [("amenity", "school"), ("name", "Школа")]),
            PBFWriter.Way(id: 200, refs: [5, 6, 7, 8, 5], tags: [("amenity", "school")]),
        ])
        try writer.finish()

        let marked = try VenueScan.duplicates(in: url)
        XCTAssertEqual(marked, [200])
    }

    func testAnExtractWithNothingToMarkMarksNothing() throws {
        let url = directory.appendingPathComponent("empty.osm.pbf")
        let writer = try PBFWriter(to: url)
        writer.header()
        writer.nodes([
            PBFWriter.Node(id: 1, lat: 44.0, lon: 33.0, tags: []),
            PBFWriter.Node(id: 2, lat: 44.0, lon: 33.01, tags: []),
            PBFWriter.Node(id: 3, lat: 44.01, lon: 33.01, tags: []),
            PBFWriter.Node(id: 4, lat: 44.01, lon: 33.0, tags: []),
        ])
        writer.ways([PBFWriter.Way(id: 100, refs: [1, 2, 3, 4, 1],
                                   tags: [("landuse", "meadow")])])
        try writer.finish()
        XCTAssertTrue(try VenueScan.duplicates(in: url).isEmpty)
    }

    // MARK: The index against the sweep it replaced

    /// The unindexed reference implementation of `mark`: every pair of every group,
    /// compared. The indexed answer must equal this one.
    private func markBySweeping(_ areas: [VenueScan.Area],
                                nodes: [(tag: String, x: Double, y: Double)]) -> Set<Int64> {
        var byTag: [String: [VenueScan.Area]] = [:]
        for area in areas { byTag[area.tag, default: []].append(area) }
        var marked = Set<Int64>()
        var nodesByTag: [String: [(x: Double, y: Double)]] = [:]
        for node in nodes { nodesByTag[node.tag, default: []].append((node.x, node.y)) }
        for (tag, group) in byTag {
            guard let here = nodesByTag[tag] else { continue }
            for area in group {
                for point in here where point.x >= area.box.x0 && point.x <= area.box.x1
                    && point.y >= area.box.y0 && point.y <= area.box.y1 {
                    if VenueScan.inside(point, area.ring) { marked.insert(area.id); break }
                }
            }
        }
        for var group in byTag.values where group.count >= 2 {
            group.sort { $0.size == $1.size ? $0.seen < $1.seen : $0.size > $1.size }
            for (i, outer) in group.enumerated() {
                for inner in group[(i + 1)...] {
                    guard inner.box.x0 >= outer.box.x0, inner.box.y0 >= outer.box.y0,
                          inner.box.x1 <= outer.box.x1, inner.box.y1 <= outer.box.y1 else { continue }
                    let centre = ((inner.box.x0 + inner.box.x1) / 2,
                                  (inner.box.y0 + inner.box.y1) / 2)
                    guard VenueScan.inside(centre, outer.ring) else { continue }
                    marked.insert(inner.named && !outer.named ? outer.id : inner.id)
                }
            }
        }
        return marked
    }

    /// Areas shaped like the real input: mostly small, a few large, clustered together
    /// with empty ground between the clusters.
    private func scatter(_ count: Int, seed: UInt64,
                         tags: [String] = ["amenity=cafe", "shop=bakery"])
    -> (areas: [VenueScan.Area], nodes: [(tag: String, x: Double, y: Double)]) {
        var state = seed
        func next() -> Double {                       // xorshift, so the case is repeatable
            state ^= state << 13; state ^= state >> 7; state ^= state << 17
            return Double(state % 1_000_000) / 1_000_000
        }
        var areas: [VenueScan.Area] = []
        var nodes: [(tag: String, x: Double, y: Double)] = []
        let towns = (0..<6).map { _ in (next() * 40, next() * 30) }
        for i in 0..<count {
            let town = towns[Int(next() * Double(towns.count)) % towns.count]
            let x = town.0 + next() * 0.2, y = town.1 + next() * 0.2
            // One area in twelve is large enough to enclose others.
            let size = next() < 0.08 ? next() * 0.15 + 0.02 : next() * 0.004 + 0.0002
            let tag = tags[i % tags.count]
            areas.append(area(Int64(i + 1), (x, y, x + size, y + size),
                              tag: tag, named: next() < 0.4, seen: i))
            if next() < 0.3 { nodes.append((tag, x + size / 2, y + size / 2)) }
        }
        return (areas, nodes)
    }

    func testTheIndexedAnswerIsTheSweptAnswer() {
        for seed in [1, 7, 99, 4242] as [UInt64] {
            let (areas, nodes) = scatter(400, seed: seed)
            XCTAssertEqual(VenueScan.mark(areas, nodes: nodes),
                           markBySweeping(areas, nodes: nodes),
                           "seed \(seed)")
        }
    }

    func testTheIndexedAnswerHoldsWhereTheGroupIsBigEnoughToIndex() {
        // Past `leastWorthIndexing` the grid is built; below it the group is walked whole.
        for count in [VenueScan.Grid.leastWorthIndexing - 1,
                      VenueScan.Grid.leastWorthIndexing,
                      VenueScan.Grid.leastWorthIndexing + 1, 900] {
            let (areas, nodes) = scatter(count, seed: 31)
            XCTAssertEqual(VenueScan.mark(areas, nodes: nodes),
                           markBySweeping(areas, nodes: nodes), "\(count) area(s)")
        }
    }

    func testAreasOfOneSizeAndOnePlaceStillAgree() {
        // Identical boxes give the levelled grid one level and one cell.
        var areas: [VenueScan.Area] = []
        for i in 0..<200 { areas.append(area(Int64(i + 1), (5, 5, 6, 6), seen: i)) }
        XCTAssertEqual(VenueScan.mark(areas, nodes: []), markBySweeping(areas, nodes: []))
    }

    func testABoxWithNoWidthDoesNotUpsetTheIndex() {
        // A zero extent sets the grid's base cell size, and must not be divided by.
        var areas: [VenueScan.Area] = []
        for i in 0..<100 {
            areas.append(area(Int64(i + 1), (0, Double(i), 10, Double(i)), seen: i))
        }
        areas.append(area(999, (0, 0, 10, 100), named: true, seen: 100))
        XCTAssertEqual(VenueScan.mark(areas, nodes: []), markBySweeping(areas, nodes: []))
    }

    func testTwoAreasAContinentApartAgree() {
        // The span needs more doublings than the grid keeps levels for, so the largest
        // level absorbs the rest.
        var areas: [VenueScan.Area] = []
        for i in 0..<80 {
            let x = Double(i) * 4
            areas.append(area(Int64(i + 1), (x, 0, x + 0.0001, 0.0001), seen: i))
        }
        areas.append(area(500, (-10, -10, 320, 320), named: true, seen: 80))
        let nodes = [("amenity=cafe", 4.00005, 0.00005)] as [(tag: String, x: Double, y: Double)]
        XCTAssertEqual(VenueScan.mark(areas, nodes: nodes), markBySweeping(areas, nodes: nodes))
    }

    func testEveryAreaCoveringAPointIsOffered() {
        // The grid's guarantee: asked about a point, it offers every area whose box holds
        // that point.
        let (areas, _) = scatter(500, seed: 5)
        var group = areas.filter { $0.tag == "amenity=cafe" }
        group.sort { $0.size == $1.size ? $0.seen < $1.seen : $0.size > $1.size }
        let grid = VenueScan.Grid(group)
        for probe in stride(from: 0.0, through: 40.0, by: 0.37) {
            for lift in [0.0, 3.1, 17.9, 29.3] {
                let point = (x: probe, y: lift)
                var offered = Set<Int>()
                grid.candidates(at: point) { offered.insert($0) }
                for (i, area) in group.enumerated()
                where point.x >= area.box.x0 && point.x <= area.box.x1
                    && point.y >= area.box.y0 && point.y <= area.box.y1 {
                    XCTAssertTrue(offered.contains(i),
                                  "area \(area.id) covers \(point) and was not offered")
                }
            }
        }
    }
}
