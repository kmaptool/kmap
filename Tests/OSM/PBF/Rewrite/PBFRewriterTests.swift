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

    /// A multipolygon is labelled as a way is: its description and its name are tidied and
    /// cleaned too, its members kept as they were.
    func testARelationIsTidiedAndCleanedWithItsMembersKept() throws {
        let source = path("in.osm.pbf")
        let writer = try PBFWriter(to: source)
        writer.header(bbox: (minLat: 44, minLon: 33, maxLat: 45, maxLon: 34))
        writer.nodes((1...4).map { PBFWriter.Node(id: Int64($0), lat: 44 + Double($0) * 1e-3, lon: 33, tags: []) })
        writer.ways([PBFWriter.Way(id: 10, refs: [1, 2, 3, 4, 1], tags: [])])
        writer.relations([
            PBFWriter.Relation(
                id: 100,
                members: [.init(kind: 1, ref: 10, role: "outer")],
                tags: [("type", "multipolygon"), ("name", "Гостиница КрАО \u{2B50}"), ("description", "Гостиница")]
            ),
            PBFWriter.Relation(
                id: 101,
                members: [.init(kind: 0, ref: 1, role: ""), .init(kind: 1, ref: 10, role: "inner")],
                tags: [("type", "multipolygon"), ("name", "Пляж"), ("description", "платный")]
            )
        ])
        try writer.finish()

        let out = path("out.osm.pbf")
        var pass = rewriter(source)
        pass.tidyDescriptions = true
        pass.cleanLabels = true
        let tally = try pass.write(to: out)

        let relations = try read(out).relations
        XCTAssertEqual(relations.map(\.id), [100, 101])
        XCTAssertEqual(relations[0].tags.map(\.1), ["multipolygon", "Гостиница КрАО"])
        XCTAssertEqual(relations[1].tags.map(\.1), ["multipolygon", "Пляж", "платный"])
        XCTAssertEqual(relations[0].roles, ["outer"])
        XCTAssertEqual(relations[1].kinds, [0, 1])
        XCTAssertEqual(relations[1].ids, [1, 10])
        XCTAssertEqual(relations[1].roles, ["", "inner"])
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

    /// Contours start above the ids the repair invents, so the invented objects go first
    /// or the ids step back down and the split loses its fast lookups.
    func testIdsAscendWithBothContoursAndInventedObjects() throws {
        let source = try makeExtract(path("in.osm.pbf"))
        let contours = path("contours.osm.pbf")
        let writer = try PBFWriter(to: contours)
        writer.header()
        let base = ContourOutput.nodeIDBase
        writer.nodes((1...3).map { PBFWriter.Node(id: base + Int64($0), lat: 44.6, lon: 33.6, tags: []) })
        writer.ways([
            PBFWriter.Way(id: ContourOutput.wayIDBase, refs: [base + 1, base + 2], tags: [("contour", "elevation")])
        ])
        try writer.finish()

        var plan = RepairPlan()
        plan.bridges = [
            RepairPlan.Bridge(
                node: 1 << 40,
                lat: 44.51,
                lon: 33.51,
                end: 50,
                word: "kerb",
                height: 0,
                length: 3,
                middle: (44.505, 33.505),
                way: -1,
                segment: 0,
                along: 0
            )
        ]
        var pass = PBFRewriter(url: source, plan: plan, network: RoadNetwork(), language: "")
        pass.contours = [contours]
        let out = path("out.osm.pbf")
        let tally = try pass.write(to: out)
        XCTAssertEqual(tally.addedWays, 1)

        var order = ElementSequence()
        try PBFReader(url: out).read(into: &order)
        let nodes = order.seen.filter { $0.kind == "n" }.map(\.id)
        let ways = order.seen.filter { $0.kind == "w" }.map(\.id)
        XCTAssertEqual(nodes, nodes.sorted())
        XCTAssertEqual(ways, ways.sorted())
        XCTAssertEqual(ways, [1000, 1001, 1 << 40, ContourOutput.wayIDBase])
        XCTAssertTrue(order.nodesPrecedeWays)
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

    /// The rewrite reads a block's nodes and ways, never its relations, so a block that
    /// holds all 3 cannot be written again without losing them: with something to put in
    /// between it is refused; with nothing, it is copied as it is.
    func testAMixedBlockWithRelationsIsRefusedNotStripped() throws {
        let source = path("mixed.osm.pbf")
        let block = PBFBytes.mixedBlock(
            nodes: [(1, 44.5, 33.5), (2, 44.6, 33.5)],
            ways: [(10, [1, 2])],
            relations: [20]
        )
        try FileTools.write(
            Data(PBFBytes.rawBlob(kind: "OSMHeader", payload: []) + PBFBytes.rawBlob(kind: "OSMData", payload: block)),
            to: source
        )
        let untouched = path("untouched.osm.pbf")
        var copying = rewriter(source)
        XCTAssertNoThrow(try copying.write(to: untouched))
        let copied = try read(untouched)
        XCTAssertEqual(copied.nodes.count, 2)
        XCTAssertEqual(copied.ways.count, 1)

        let contours = path("contours.osm.pbf")
        let writer = try PBFWriter(to: contours)
        writer.header()
        writer.nodes([PBFWriter.Node(id: 5_000_001, lat: 44.6, lon: 33.6, tags: [])])
        try writer.finish()
        var adding = rewriter(source)
        adding.contours = [contours]
        XCTAssertThrowsError(try adding.write(to: path("out.osm.pbf"))) {
            guard case .mixedBlock = $0 as? PBFRewriter.Trouble else { return XCTFail("\($0)") }
        }
    }

    /// A relation alone in need of tidying or cleaning leaves a mixed block copied whole.
    func testAMixedBlockIsCopiedForWhatOnlyItsRelationsNeed() throws {
        let needs = [[("name", "Пляж \u{2B50}")], [("name", "Гостиница КрАО"), ("description", "Гостиница")]]
        XCTAssertTrue(PBFRewriter.hasUnprintable(needs[0][0].1))
        XCTAssertTrue(PBFRewriter.wouldTidy(needs[1]))
        for tags in needs {
            let source = path("mixed.osm.pbf")
            let block = PBFBytes.mixedBlock(
                nodes: [(1, 44.5, 33.5), (2, 44.6, 33.5)],
                ways: [(10, [1, 2])],
                relations: [20],
                relationTags: tags
            )
            try FileTools.write(
                Data(
                    PBFBytes.rawBlob(kind: "OSMHeader", payload: []) + PBFBytes.rawBlob(kind: "OSMData", payload: block)
                ),
                to: source
            )
            var pass = rewriter(source)
            pass.tidyDescriptions = true
            pass.cleanLabels = true
            XCTAssertNoThrow(try pass.write(to: path("out.osm.pbf")), "\(tags)")
        }
    }

    /// The output is emptied before the input is read, so 1 file for both, by any
    /// spelling, is refused before anything is written.
    func testWritingOverTheInputIsRefusedAndTheInputKept() throws {
        let source = try makeExtract(path("in.osm.pbf"))
        let before = try Data(contentsOf: source)
        let spelled = directory.appendingPathComponent("sub/../in.osm.pbf")
        try FileManager.default.createDirectory(at: path("sub"), withIntermediateDirectories: true)
        var pass = rewriter(source)
        XCTAssertThrowsError(try pass.write(to: spelled)) {
            guard case .writesOverItsInput = $0 as? PBFRewriter.Trouble else { return XCTFail("\($0)") }
        }
        XCTAssertEqual(try Data(contentsOf: source), before)
        XCTAssertThrowsError(try AnnotatePass(source: source, destination: source).run { _ in })
        XCTAssertEqual(try Data(contentsOf: source), before)
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
        // A part of the name adds nothing to it: the label would read "Holy Spring (Spring)".
        XCTAssertEqual(dropped([("name", "Родник Святой"), ("description", "Родник")]).count, 1)
        // No name, nothing to compare against.
        XCTAssertEqual(dropped([("description", "Родник")]).count, 1)
        // An empty name is no name.
        XCTAssertEqual(dropped([("name", ""), ("description", "Родник")]).count, 2)
        // The language-tagged pairs travel together.
        XCTAssertEqual(dropped([("name:ru", "Родник"), ("description:ru", "Родник")]).count, 1)
        XCTAssertEqual(dropped([("name", "Spring"), ("description:en", "spring")]).count, 1)
        // Whole words only: a status word, a number or a fragment says something new.
        XCTAssertEqual(dropped([("name", "Закрытый пляж"), ("description", "закрыт")]).count, 2)
        XCTAssertEqual(dropped([("name", "Школа №15"), ("description", "1")]).count, 2)
        XCTAssertEqual(dropped([("name", "Кафе Лето"), ("description", "фел")]).count, 2)
        // Each name the label may be made of counts, the Russian one included.
        XCTAssertEqual(dropped([("name:ru", "Родник"), ("name", "Spring"), ("description", "Родник")]).count, 2)
        XCTAssertEqual(dropped([("name:ru", "Родник"), ("name", "Spring"), ("description", "Spring")]).count, 2)
        // Unnamed, the label is the Russian word for the kind: a description repeating it
        // goes, unless an operator takes the label instead. A ref follows the word.
        XCTAssertEqual(dropped([("man_made", "water_well"), ("description", "Колодец")]).count, 1)
        XCTAssertEqual(
            dropped([("man_made", "water_well"), ("operator", "Водоканал"), ("description", "Колодец")]).count,
            3
        )
        XCTAssertEqual(
            dropped([("tourism", "hotel"), ("ref", "КРАО"), ("description", "Гостиница")]).count,
            2
        )
        XCTAssertEqual(dropped([("tourism", "hotel"), ("ref", "КРАО"), ("description", "КРАО")]).count, 2)
        XCTAssertEqual(dropped([("tourism", "hotel"), ("ref", "КРАО"), ("description", "у моря")]).count, 3)
        // An open line and a barrier keep the word beside an operator: so does the tidy.
        var pier = [("man_made", "pier"), ("operator", "Порт"), ("description", "Пирс")]
        XCTAssertEqual(PBFRewriter.tidy(&pier, wordStays: true), 1)
        XCTAssertTrue(PBFRewriter.wordStays(refs: [1, 2, 3], tags: []))
        XCTAssertFalse(PBFRewriter.wordStays(refs: [1, 2, 3, 1], tags: [("amenity", "school")]))
        XCTAssertTrue(PBFRewriter.wordStays(refs: [1, 2, 3, 1], tags: [("barrier", "fence")]))
        // Other tags are never touched.
        XCTAssertEqual(
            dropped([
                ("name", "Родник"), ("description", "Родник"),
                ("natural", "spring")
            ]).map(\.0),
            ["name", "natural"]
        )
    }

    /// What no code page draws goes from a label's text, and nothing else does.
    func testStressMarksAndEmojiLeaveTheName() {
        var tags = [
            ("name", "Михаи\u{301}л Барклай"), ("description", "Балтия \u{1F6CD}\u{FE0F} молл"),
            ("website", "http://x.ru/\u{1F600}"), ("name:ru", "Запо\u{301}лье")
        ]
        XCTAssertTrue(tags.contains { PBFRewriter.hasUnprintable($0.1) })
        PBFRewriter.clean(&tags)
        XCTAssertEqual(tags.map(\.1), ["Михаил Барклай", "Балтия молл", "http://x.ru/\u{1F600}", "Заполье"])
        XCTAssertFalse(PBFRewriter.hasUnprintable("Родник — «Святой»"))
        // A letter written as 2 code points is composed, not dropped.
        var short = [("name", "Белыи\u{306}")]
        XCTAssertTrue(PBFRewriter.hasUnprintable(short[0].1))
        PBFRewriter.clean(&short)
        XCTAssertEqual(short[0].1, "Белый")
        var heart = [("name", "Я \u{2764}\u{FE0F} Керчь")]
        PBFRewriter.clean(&heart)
        XCTAssertEqual(heart[0].1, "Я Керчь")
        // The joiners stay only for the page that has them.
        let persian = "\u{0645}\u{06CC}\u{200C}\u{0631}\u{200D}\u{0648}\u{0645}"
        var dropped = [("name", persian)]
        PBFRewriter.clean(&dropped)
        XCTAssertEqual(dropped[0].1, "\u{0645}\u{06CC}\u{0631}\u{0648}\u{0645}")
        var kept = [("name", persian)]
        PBFRewriter.clean(&kept, keepingJoiners: true)
        XCTAssertEqual(kept[0].1, persian)
        // Not the joiners an emoji leaves behind.
        var family = [
            ("name", "\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467} Family"),
            ("name:fa", "Caf\u{E9} \u{2764}\u{FE0F}\u{200D}\u{1F525}")
        ]
        PBFRewriter.clean(&family, keepingJoiners: true)
        XCTAssertEqual(family.map(\.1), ["Family", "Caf\u{E9}"])
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
        for tags in cases + [[("man_made", "pier"), ("operator", "Порт"), ("description", "Пирс")]] {
            for stays in [false, true] {
                var copy = tags
                let dropped = PBFRewriter.tidy(&copy, wordStays: stays) > 0
                XCTAssertEqual(PBFRewriter.wouldTidy(tags, wordStays: stays), dropped, "\(tags)")
            }
        }
    }

    /// On a Russian map a Georgian name with an English one beside it is labelled in English.
    func testANameTheCodePageCannotDrawIsSwapped() throws {
        let source = try makeExtract(
            path("in.osm.pbf"),
            nodes: [
                PBFWriter.Node(id: 1, lat: 42.9, lon: 43.4, tags: [("name", "ზოფხიტური"), ("name:en", "Zopkhituri")]),
                PBFWriter.Node(id: 2, lat: 42.9, lon: 43.4, tags: [("name", "Ставрополь"), ("name:en", "Stavropol")])
            ],
            ways: []
        )
        let out = path("out.osm.pbf")
        var pass = rewriter(source)
        pass.cleanLabels = true
        pass.nameOrder = ["name:ru", "name", "int_name", "name:en"]
        pass.codePage = CodePage.cyrillic
        let tally = try pass.write(to: out)
        let after = try read(out)
        XCTAssertEqual(after.nodes.first { $0.id == 1 }?.tags.first { $0.0 == "name" }?.1, "Zopkhituri")
        XCTAssertEqual(after.nodes.first { $0.id == 2 }?.tags.first { $0.0 == "name" }?.1, "Ставрополь")
        XCTAssertEqual(tally.renamed, 1)
    }

    /// A name the cleaning empties is none, alone in its block or not: the next one is
    /// judged, as mkgmap drops the empty tag.
    func testANameEmptiedByCleaningGivesWay() throws {
        let source = try makeExtract(
            path("in.osm.pbf"),
            nodes: [
                PBFWriter.Node(
                    id: 1,
                    lat: 42.9,
                    lon: 43.4,
                    tags: [("name:ru", "🏔"), ("name", "ზოფხიტური"), ("name:en", "Zopkhituri")]
                )
            ],
            ways: []
        )
        let out = path("out.osm.pbf")
        var pass = rewriter(source)
        pass.cleanLabels = true
        pass.nameOrder = ["name:ru", "name", "int_name", "name:en"]
        pass.codePage = CodePage.cyrillic
        let tally = try pass.write(to: out)
        let tags = try XCTUnwrap(try read(out).nodes.first?.tags)
        XCTAssertEqual(tags.first { $0.0 == "name" }?.1, "Zopkhituri")
        XCTAssertEqual(tally.renamed, 1)
    }

    /// A name that reads leaves its block as it was, whatever other languages it carries.
    func testABlockWhoseNamesReadIsCopied() throws {
        let source = try makeExtract(
            path("in.osm.pbf"),
            nodes: [PBFWriter.Node(id: 1, lat: 55.7, lon: 37.6, tags: [("name", "Москва"), ("name:zh", "莫斯科")])],
            ways: []
        )
        var pass = rewriter(source)
        pass.cleanLabels = true
        pass.nameOrder = ["name:ru", "name", "int_name", "name:en"]
        pass.codePage = CodePage.cyrillic
        let tally = try pass.write(to: path("out.osm.pbf"))
        XCTAssertEqual(tally.rebuilt, 0)
        XCTAssertEqual(tally.renamed, 0)
    }
}
