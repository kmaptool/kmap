import XCTest

@testable import kmap

/// The single pass over an extract that precedes mkgmap: barrier classes, tidied
/// descriptions, duplicate venues, repaired road ends, contours folded in.
///
/// Checks that the parts combine without loss: everything that went in comes out, plus the
/// additions and nothing else.
final class AnnotatePassTests: XCTestCase {
    private var directory = URL(fileURLWithPath: "/tmp")

    override func setUpWithError() throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("kmap-annotate-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func path(_ name: String) -> URL { directory.appendingPathComponent(name) }

    private struct Collected: OSMSink {
        var nodes: [(id: Int64, tags: [String: String])] = []
        var ways: [(id: Int64, refs: [Int64], tags: [String: String])] = []

        mutating func node(
            id: Int64,
            lat: Double,
            lon: Double,
            tags: ArraySlice<Int32>,
            block: OSMBlock
        ) {
            var pairs: [String: String] = [:]
            var i = tags.startIndex
            while i + 1 < tags.endIndex {
                pairs[block.text(Int(tags[i]))] = block.text(Int(tags[i + 1]))
                i += 2
            }
            nodes.append((id, pairs))
        }

        mutating func way(
            id: Int64,
            refs: ArraySlice<Int64>,
            keys: ArraySlice<Int32>,
            values: ArraySlice<Int32>,
            block: OSMBlock
        ) {
            var pairs: [String: String] = [:]
            for (key, value) in zip(keys, values) {
                pairs[block.text(Int(key))] = block.text(Int(value))
            }
            ways.append((id, Array(refs), pairs))
        }
    }

    private func read(_ url: URL) throws -> Collected {
        var collected = Collected()
        try PBFReader(url: url).read(into: &collected)
        return collected
    }

    /// Writes an extract holding a track with a gate on it, a point whose description
    /// repeats its name, and a second track stopping two metres short of the first.
    private func makeExtract() throws -> URL {
        let url = path("in.osm.pbf")
        let metre = 1 / RoadRepair.metresPerDegree
        let writer = try PBFWriter(to: url)
        writer.header(bbox: (minLat: 44.4, minLon: 33.4, maxLat: 44.6, maxLon: 33.6))
        writer.nodes([
            PBFWriter.Node(id: 1, lat: 44.5, lon: 33.5, tags: []),
            PBFWriter.Node(id: 2, lat: 44.5, lon: 33.502, tags: [("barrier", "gate")]),
            PBFWriter.Node(id: 3, lat: 44.5 + 2 * metre, lon: 33.501, tags: []),
            PBFWriter.Node(id: 4, lat: 44.502, lon: 33.501, tags: []),
            PBFWriter.Node(
                id: 5,
                lat: 44.51,
                lon: 33.51,
                tags: [
                    ("natural", "spring"), ("name", "Родник"),
                    ("description", "Родник")
                ]
            )
        ])
        writer.ways([
            PBFWriter.Way(id: 10, refs: [1, 2], tags: [("highway", "track")]),
            PBFWriter.Way(id: 11, refs: [3, 4], tags: [("highway", "path")])
        ])
        try writer.finish()
        return url
    }

    func testEverythingInTheExtractComesOutOfIt() throws {
        let source = try makeExtract()
        let out = path("out.osm.pbf")
        let pass = AnnotatePass(source: source, destination: out)
        let tally = try pass.run { _ in }

        let before = try read(source)
        let after = try read(out)
        XCTAssertEqual(after.nodes.map(\.id).sorted(), before.nodes.map(\.id).sorted())
        XCTAssertEqual(after.ways.map(\.id).sorted(), before.ways.map(\.id).sorted())
        XCTAssertGreaterThan(tally.copied + tally.rebuilt, 0)
    }

    /// ^C reaches every read of the pass and its rewrite: they run on threads of their own,
    /// where a task's cancellation is not seen.
    func testAStopAskedForEndsThePassAndEveryScan() throws {
        let source = try makeExtract()
        var pass = AnnotatePass(source: source, destination: path("out.osm.pbf"))
        pass.repairRadius = 10
        pass.markDuplicateVenues = true
        // Counted: the pass asks once itself after the scans, which alone would end it
        // even were the scans, on threads of their own, never told.
        let asked = Locked(0)
        pass.shouldStop = {
            asked.withLock { $0 += 1 }
            return true
        }
        XCTAssertThrowsError(try pass.run { _ in }) { XCTAssertTrue($0 is CancellationError, "\($0)") }
        XCTAssertGreaterThanOrEqual(asked.withLock { $0 }, 4, "each of the 3 scans asked as well")
        XCTAssertThrowsError(try BarrierScan.classify(source, shouldStop: { true })) {
            XCTAssertTrue($0 is CancellationError)
        }
        XCTAssertThrowsError(try VenueScan.duplicates(in: source, shouldStop: { true })) {
            XCTAssertTrue($0 is CancellationError)
        }
        XCTAssertThrowsError(try RoadNetworkLoader(url: source, shouldStop: { true }).load()) {
            XCTAssertTrue($0 is CancellationError)
        }
        XCTAssertThrowsError(try WaterScan.bodies(in: source, shouldStop: { true })) {
            XCTAssertTrue($0 is CancellationError)
        }
        var rewriter = PBFRewriter(url: source, plan: RepairPlan(), network: RoadNetwork(), language: "en")
        rewriter.shouldStop = { true }
        XCTAssertThrowsError(try rewriter.write(to: path("rewritten.osm.pbf"))) {
            XCTAssertTrue($0 is CancellationError)
        }
    }

    func testTheGateIsToldWhatItStandsOn() throws {
        let source = try makeExtract()
        let out = path("out.osm.pbf")
        _ = try AnnotatePass(source: source, destination: out).run { _ in }
        let gate = try read(out).nodes.first { $0.id == 2 }
        XCTAssertEqual(gate?.tags["kmap:on"], "path")
        XCTAssertEqual(gate?.tags["barrier"], "gate")
    }

    func testADescriptionRepeatingTheNameGoesOnlyWhenAsked() throws {
        let source = try makeExtract()
        let kept = path("kept.osm.pbf")
        _ = try AnnotatePass(source: source, destination: kept).run { _ in }
        XCTAssertEqual(
            try read(kept).nodes.first { $0.id == 5 }?.tags["description"],
            "Родник"
        )

        let tidied = path("tidied.osm.pbf")
        var pass = AnnotatePass(source: source, destination: tidied)
        pass.dropDuplicateDescriptions = true
        let tally = try pass.run { _ in }
        XCTAssertEqual(tally.dropped, 1)
        XCTAssertNil(try read(tidied).nodes.first { $0.id == 5 }?.tags["description"])
        XCTAssertEqual(try read(tidied).nodes.first { $0.id == 5 }?.tags["name"], "Родник")
    }

    func testTheRoadsAreLeftExactlyAsOSMHasThemWhenTheRadiusIsZero() throws {
        let source = try makeExtract()
        let out = path("out.osm.pbf")
        let tally = try AnnotatePass(source: source, destination: out).run { _ in }
        XCTAssertEqual(tally.addedNodes, 0)
        XCTAssertEqual(tally.addedWays, 0)
        let after = try read(out)
        XCTAssertEqual(after.ways.first { $0.id == 11 }?.refs, [3, 4])
    }

    func testAGapIsClosedWhenTheRadiusAllowsIt() throws {
        let source = try makeExtract()
        let out = path("out.osm.pbf")
        var pass = AnnotatePass(source: source, destination: out)
        pass.repairRadius = 5
        var log: [String] = []
        _ = try pass.run { log.append($0) }
        XCTAssertTrue(log.contains { $0.contains("joined") }, log.joined(separator: "\n"))

        // The path now shares a node with the track.
        let after = try read(out)
        let track: [Int64] = after.ways.first { $0.id == 10 }?.refs ?? []
        let joined: [Int64] = after.ways.first { $0.id == 11 }?.refs ?? []
        XCTAssertFalse(
            Set(track).intersection(Set(joined)).isEmpty,
            "the two ways still share nothing"
        )
    }

    /// A path starting on a kerb's vertex keeps that node where it is: the path is
    /// lengthened at its start to a new node on the track, which the track takes in too.
    func testAnEndOnAKerbIsLengthenedNotMoved() throws {
        let url = path("kerb.osm.pbf")
        let metre = 1 / RoadRepair.metresPerDegree
        let writer = try PBFWriter(to: url)
        writer.header(bbox: (minLat: 44.4, minLon: 33.4, maxLat: 44.6, maxLon: 33.6))
        let end = (lat: 44.5 + 3 * metre, lon: 33.501)
        writer.nodes([
            PBFWriter.Node(id: 1, lat: 44.5, lon: 33.5, tags: []),
            PBFWriter.Node(id: 2, lat: 44.5, lon: 33.502, tags: []),
            PBFWriter.Node(id: 3, lat: end.lat, lon: end.lon, tags: []),
            PBFWriter.Node(id: 4, lat: 44.502, lon: 33.501, tags: []),
            PBFWriter.Node(id: 6, lat: end.lat, lon: 33.5005, tags: []),
            PBFWriter.Node(id: 7, lat: end.lat, lon: 33.5015, tags: [])
        ])
        writer.ways([
            PBFWriter.Way(id: 10, refs: [1, 2], tags: [("highway", "track")]),
            PBFWriter.Way(id: 11, refs: [3, 4], tags: [("highway", "path")]),
            PBFWriter.Way(id: 12, refs: [6, 3, 7], tags: [("barrier", "kerb")])
        ])
        try writer.finish()

        let out = path("out.osm.pbf")
        var pass = AnnotatePass(source: url, destination: out)
        pass.repairRadius = 5
        _ = try pass.run { _ in }
        let after = try read(out)
        let track = try XCTUnwrap(after.ways.first { $0.id == 10 }?.refs)
        let footway = try XCTUnwrap(after.ways.first { $0.id == 11 }?.refs)
        XCTAssertEqual(footway.count, 3, "\(footway)")
        XCTAssertEqual(Array(footway.dropFirst()), [3, 4])
        XCTAssertTrue(track.contains(footway[0]), "\(track)")
        XCTAssertEqual(after.ways.first { $0.id == 12 }?.refs, [6, 3, 7])
    }

    func testElevationAlreadyAtHandHoldsNothingUp() throws {
        // A rebuild has the tiles before the scans ask: the stage is never shown waiting.
        let source = try makeExtract()
        var pass = AnnotatePass(source: source, destination: path("out.osm.pbf"))
        pass.repairRadius = 5
        let asked = Counter()
        pass.demReady = {
            asked.increment()
            return []
        }
        pass.demAtHand = { [] }
        let held = Locked<[Bool]>([])
        pass.onHeld = { value in held.withLock { $0.append(value) } }
        _ = try pass.run { _ in }
        XCTAssertEqual(held.withLock { $0 }, [])
        XCTAssertEqual(asked.value, 0, "nothing to wait for")
    }

    func testContourFilesAreFoldedIn() throws {
        let source = try makeExtract()
        let contours = path("contours.osm.pbf")
        let writer = try PBFWriter(to: contours)
        writer.header()
        writer.nodes(
            (1...10).map {
                PBFWriter.Node(id: 20_000_000_000 + Int64($0), lat: 44.5, lon: 33.5, tags: [])
            }
        )
        writer.ways([
            PBFWriter.Way(
                id: 5_000_000_001,
                refs: (1...10).map { 20_000_000_000 + Int64($0) },
                tags: [("contour", "elevation"), ("ele", "100")]
            )
        ])
        try writer.finish()

        let out = path("out.osm.pbf")
        var pass = AnnotatePass(source: source, destination: out)
        pass.contours = [contours]
        let tally = try pass.run { _ in }
        XCTAssertGreaterThan(tally.contourBlocks, 0)

        let after = try read(out)
        XCTAssertTrue(after.ways.contains { $0.id == 5_000_000_001 })
        XCTAssertTrue(after.nodes.contains { $0.id == 20_000_000_001 })
        XCTAssertTrue(after.ways.contains { $0.id == 10 })
    }

    func testTheLogSaysWhatWasDone() throws {
        let source = try makeExtract()
        var log: [String] = []
        var pass = AnnotatePass(source: source, destination: path("out.osm.pbf"))
        pass.dropDuplicateDescriptions = true
        _ = try pass.run { log.append($0) }
        let text = log.joined(separator: "\n")
        XCTAssertTrue(text.contains("annotated"), text)
        XCTAssertTrue(text.contains("description"), text)
    }
}
