import XCTest

@testable import kmap

/// Writing a repaired copy of an extract: some blocks rebuilt, the rest copied as bytes.
///
/// Checked whole, file in and file out: objects the pass did not mean to touch come out
/// untouched.
final class PBFRewriterTests: XCTestCase {
    private var directory = URL(fileURLWithPath: "/tmp")

    override func setUpWithError() throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("kmap-rewriter-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func path(_ name: String) -> URL { directory.appendingPathComponent(name) }

    private func read(_ url: URL) throws -> CollectedElements {
        var collected = CollectedElements()
        try PBFReader(url: url).read(into: &collected)
        return collected
    }

    /// A small extract: nodes with tags, ways over them.
    @discardableResult
    private func makeExtract(
        _ url: URL,
        nodes: [PBFWriter.Node]? = nil,
        ways: [PBFWriter.Way]? = nil
    ) throws -> URL {
        let writer = try PBFWriter(to: url)
        writer.header(bbox: (minLat: 44, minLon: 33, maxLat: 45, maxLon: 34))
        writer.nodes(
            nodes
                ?? (1...100).map {
                    PBFWriter.Node(
                        id: Int64($0),
                        lat: 44.5 + Double($0) * 1e-4,
                        lon: 33.5,
                        tags: [("name", "node \($0)")]
                    )
                }
        )
        writer.ways(
            ways ?? [
                PBFWriter.Way(id: 1000, refs: Array(1...50), tags: [("highway", "track")]),
                PBFWriter.Way(id: 1001, refs: Array(51...100), tags: [("highway", "path")])
            ]
        )
        try writer.finish()
        return url
    }

    private func rewriter(_ source: URL) -> PBFRewriter {
        PBFRewriter(url: source, plan: RepairPlan(), network: RoadNetwork(), language: "")
    }

    // MARK: Copying

    func testAnExtractWithNothingToRepairComesOutWithEveryObjectIntact() throws {
        let source = try makeExtract(path("in.osm.pbf"))
        let out = path("out.osm.pbf")
        let tally = try {
            var made = rewriter(source); return try made.write(to: out)
        }()

        let before = try read(source)
        let after = try read(out)
        XCTAssertEqual(after.nodes.map(\.id), before.nodes.map(\.id))
        XCTAssertEqual(after.ways.map(\.id), before.ways.map(\.id))
        XCTAssertEqual(after.ways.first?.refs, before.ways.first?.refs)
        XCTAssertEqual(after.nodes[0].tags.map(\.1), ["node 1"])
        XCTAssertGreaterThan(tally.copied, 0)
        XCTAssertEqual(tally.rebuilt, 0)
    }

    func testTheHeaderTravelsWithTheFile() throws {
        let source = try makeExtract(path("in.osm.pbf"))
        let out = path("out.osm.pbf")
        _ = try {
            var made = rewriter(source); return try made.write(to: out)
        }()
        let box = try PBFReader(url: out).headerBBox()
        XCTAssertEqual(box?.minLat ?? 0, 44, accuracy: 1e-9)
        XCTAssertEqual(box?.maxLon ?? 0, 34, accuracy: 1e-9)
    }

    func testManyBlocksAllComeThroughInOrder() throws {
        // Past the width of the batch the pass inflates in; a block returned out of order
        // shows up as an id out of sequence.
        let source = path("many.osm.pbf")
        let writer = try PBFWriter(to: source)
        writer.header()
        for batch in 0..<30 {
            writer.nodes(
                (0..<1000).map {
                    PBFWriter.Node(id: Int64(batch * 1000 + $0 + 1), lat: 44, lon: 33, tags: [])
                }
            )
        }
        try writer.finish()

        let out = path("many-out.osm.pbf")
        _ = try {
            var made = rewriter(source); return try made.write(to: out)
        }()
        XCTAssertEqual(try read(out).nodes.map(\.id), Array(1...30_000))
    }

    // MARK: Changing what it was asked to change

    func testABarrierNodeIsToldWhichKindOfWayItStandsOn() throws {
        let source = try makeExtract(path("in.osm.pbf"))
        let out = path("out.osm.pbf")
        var pass = rewriter(source)
        pass.barriers = [7: "minor", 9: "path"]
        let tally = try pass.write(to: out)

        let after = try read(out)
        let seven = after.nodes.first { $0.id == 7 }
        XCTAssertEqual(seven?.tags.first { $0.0 == "kmap:on" }?.1, "minor")
        XCTAssertEqual(
            after.nodes.first { $0.id == 9 }?.tags.first { $0.0 == "kmap:on" }?.1,
            "path"
        )
        // And nothing else was touched.
        XCTAssertNil(after.nodes.first { $0.id == 8 }?.tags.first { $0.0 == "kmap:on" })
        XCTAssertEqual(tally.tagged, 2)
        XCTAssertEqual(after.nodes.count, 100)
    }

    func testAnAreaThatRepeatsAVenueIsMarkedForTheStyle() throws {
        let source = try makeExtract(path("in.osm.pbf"))
        let out = path("out.osm.pbf")
        var pass = rewriter(source)
        pass.duplicateVenues = [1000]
        let tally = try pass.write(to: out)

        let after = try read(out)
        XCTAssertEqual(
            after.ways.first { $0.id == 1000 }?
                .tags.first { $0.0 == "kmap:dup_venue" }?.1,
            "yes"
        )
        XCTAssertNil(
            after.ways.first { $0.id == 1001 }?
                .tags.first { $0.0 == "kmap:dup_venue" }
        )
        XCTAssertEqual(tally.marked, 1)
    }

    func testADescriptionThatOnlyRepeatsTheNameIsDropped() throws {
        let source = try makeExtract(
            path("in.osm.pbf"),
            nodes: [
                PBFWriter.Node(
                    id: 1,
                    lat: 44,
                    lon: 33,
                    tags: [("name", "Родник"), ("description", "Родник")]
                ),
                PBFWriter.Node(
                    id: 2,
                    lat: 44,
                    lon: 33,
                    tags: [("name", "Родник"), ("description", "вода круглый год")]
                )
            ],
            ways: []
        )
        let out = path("out.osm.pbf")
        var pass = rewriter(source)
        pass.tidyDescriptions = true
        let tally = try pass.write(to: out)

        let after = try read(out)
        XCTAssertNil(after.nodes.first { $0.id == 1 }?.tags.first { $0.0 == "description" })
        XCTAssertEqual(
            after.nodes.first { $0.id == 2 }?
                .tags.first { $0.0 == "description" }?.1,
            "вода круглый год"
        )
        XCTAssertEqual(tally.dropped, 1)
    }

    func testWithNothingToTidyTheBlocksAreStillOnlyCopied() throws {
        let source = try makeExtract(path("in.osm.pbf"))
        let out = path("out.osm.pbf")
        var pass = rewriter(source)
        pass.tidyDescriptions = true  // on, but nothing in the file matches
        let tally = try pass.write(to: out)
        XCTAssertEqual(tally.rebuilt, 0)
        XCTAssertEqual(try read(out).nodes.count, 100)
    }

    // MARK: Folding contours in

    func testContourFilesAreFoldedInWithTheirNodesBeforeTheirWays() throws {
        let source = try makeExtract(path("in.osm.pbf"))
        let contours = path("contours.osm.pbf")
        let writer = try PBFWriter(to: contours)
        writer.header()
        writer.nodes(
            (1...20).map {
                PBFWriter.Node(id: 5_000_000 + Int64($0), lat: 44.6, lon: 33.6, tags: [])
            }
        )
        writer.ways([
            PBFWriter.Way(
                id: 6_000_000,
                refs: (1...20).map { 5_000_000 + Int64($0) },
                tags: [("contour", "elevation"), ("ele", "100")]
            )
        ])
        try writer.finish()

        let out = path("out.osm.pbf")
        var pass = rewriter(source)
        pass.contours = [contours]
        let tally = try pass.write(to: out)

        let after = try read(out)
        XCTAssertTrue(after.nodes.contains { $0.id == 5_000_001 })
        XCTAssertTrue(after.ways.contains { $0.id == 6_000_000 })
        XCTAssertGreaterThan(tally.contourBlocks, 0)

        // A PBF is read front to back and mkgmap wants every node before the ways that
        // name it: the contour nodes must land before the contour way.
        var order = ElementSequence()
        try PBFReader(url: out).read(into: &order)
        XCTAssertTrue(order.nodesPrecedeWays, "a node after the first way")
        XCTAssertEqual(order.seen.last?.id, 6_000_000)
    }

    /// A block holding nodes as well as ways, which other tools write. The added nodes
    /// go after the block's own nodes and before its ways, so ids still ascend and every
    /// node still precedes every way.
    func testAMixedBlockKeepsTheAddedNodesBetweenItsNodesAndItsWays() throws {
        let source = path("mixed.osm.pbf")
        let block = PBFBytes.mixedBlock(
            nodes: [(1, 44.5, 33.5), (2, 44.6, 33.5), (3, 44.7, 33.5)],
            ways: [(10, [1, 2, 3])]
        )
        try FileTools.write(
            Data(PBFBytes.rawBlob(kind: "OSMHeader", payload: []) + PBFBytes.rawBlob(kind: "OSMData", payload: block)),
            to: source
        )
        let contours = path("contours.osm.pbf")
        let writer = try PBFWriter(to: contours)
        writer.header()
        writer.nodes([PBFWriter.Node(id: 5_000_001, lat: 44.6, lon: 33.6, tags: [])])
        writer.ways([PBFWriter.Way(id: 6_000_000, refs: [5_000_001], tags: [("contour", "elevation")])])
        try writer.finish()

        let out = path("out.osm.pbf")
        var pass = rewriter(source)
        pass.contours = [contours]
        _ = try pass.write(to: out)

        var order = ElementSequence()
        try PBFReader(url: out).read(into: &order)
        XCTAssertEqual(order.seen.map(\.id), [1, 2, 3, 5_000_001, 10, 6_000_000])
        XCTAssertTrue(order.nodesPrecedeWays)
    }

    // MARK: Files that are wrong

    func testATruncatedExtractIsRefusedOrReadShortNeverCrashing() throws {
        // A cut inside a blob is refused; a cut on a blob boundary is a shorter file, and
        // the copy then holds no more than the original did.
        let source = try makeExtract(path("in.osm.pbf"))
        let whole = try Data(contentsOf: source)
        let full = try read(source)
        var refused = 0
        for cut in stride(from: 4, to: whole.count, by: max(1, whole.count / 12)) {
            let cutURL = path("cut-\(cut).osm.pbf")
            try FileTools.write(whole.prefix(cut), to: cutURL)
            var made = rewriter(cutURL)
            let outURL = path("out-\(cut).osm.pbf")
            do {
                _ = try made.write(to: outURL)
                let short = try read(outURL)
                XCTAssertLessThanOrEqual(short.nodes.count, full.nodes.count)
                XCTAssertLessThanOrEqual(short.ways.count, full.ways.count)
            } catch {
                refused += 1
            }
        }
        XCTAssertGreaterThan(refused, 0, "no cut landed inside a blob")
    }

    // MARK: Tidying, on its own

    func testTidyDropsWhatTheNameAlreadySays() {
        func dropped(_ tags: [(String, String)]) -> [(String, String)] {
            var copy = tags
            _ = PBFRewriter.tidy(&copy)
            return copy
        }
        // The same, but for case and surrounding space.
        XCTAssertEqual(dropped([("name", "Родник"), ("description", " родник ")]).count, 1)
        // The same but for punctuation and spacing.
        XCTAssertEqual(dropped([("name", "Родник"), ("description", "Родник.")]).count, 1)
        XCTAssertEqual(dropped([("name", "Кафе 24/7"), ("description", "Кафе 24 / 7")]).count, 1)
        // Empty says nothing at all.
        XCTAssertEqual(dropped([("name", "Родник"), ("description", "")]).count, 1)
        // Genuinely more to say, and it stays.
        XCTAssertEqual(dropped([("name", "Родник"), ("description", "вода круглый год")]).count, 2)
        XCTAssertEqual(dropped([("name", "Родник"), ("description", "Родник у дороги")]).count, 2)
        // One added word can be the whole point: a dry spring on a hiking map.
        XCTAssertEqual(dropped([("name", "Родник"), ("description", "Родник сух")]).count, 2)
        XCTAssertEqual(dropped([("name", "Кафе"), ("description", "Кафе 24/7")]).count, 2)
        // Less than the name is not the name either.
        XCTAssertEqual(dropped([("name", "Родник Святой"), ("description", "Родник")]).count, 2)
        // No name, nothing to compare against.
        XCTAssertEqual(dropped([("description", "Родник")]).count, 1)
        // An empty name is no name.
        XCTAssertEqual(dropped([("name", ""), ("description", "Родник")]).count, 2)
        // The language-tagged pairs travel together.
        XCTAssertEqual(dropped([("name:ru", "Родник"), ("description:ru", "Родник")]).count, 1)
        XCTAssertEqual(dropped([("name", "Spring"), ("description:en", "spring")]).count, 1)
        // `name` is measured against first, whatever order the tags come in.
        XCTAssertEqual(dropped([("name:ru", "Родник"), ("name", "Spring"), ("description", "Родник")]).count, 3)
        XCTAssertEqual(dropped([("name:ru", "Родник"), ("name", "Spring"), ("description", "Spring")]).count, 2)
        // Other tags are never touched.
        XCTAssertEqual(
            dropped([
                ("name", "Родник"), ("description", "Родник"),
                ("natural", "spring")
            ]).map(\.0),
            ["name", "natural"]
        )
    }

    func testWouldTidyAgreesWithTidy() {
        let cases: [[(String, String)]] = [
            [("name", "A"), ("description", "A")],
            [("name", "A"), ("description", "B")],
            [("name", "A")],
            [],
            [("description", "A")],
            [("name", "Родник"), ("description", "Родник."), ("natural", "spring")]
        ]
        for tags in cases {
            var copy = tags
            let dropped = PBFRewriter.tidy(&copy) > 0
            XCTAssertEqual(PBFRewriter.wouldTidy(tags), dropped, "\(tags)")
        }
    }
}
