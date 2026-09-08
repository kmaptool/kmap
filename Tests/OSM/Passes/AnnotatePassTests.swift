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

        mutating func node(id: Int64, lat: Double, lon: Double,
                           tags: ArraySlice<Int32>, block: OSMBlock) {
            var pairs: [String: String] = [:]
            var i = tags.startIndex
            while i + 1 < tags.endIndex {
                pairs[block.text(Int(tags[i]))] = block.text(Int(tags[i + 1]))
                i += 2
            }
            nodes.append((id, pairs))
        }

        mutating func way(id: Int64, refs: ArraySlice<Int64>, keys: ArraySlice<Int32>,
                          values: ArraySlice<Int32>, block: OSMBlock) {
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
            PBFWriter.Node(id: 5, lat: 44.51, lon: 33.51,
                           tags: [("natural", "spring"), ("name", "Родник"),
                                  ("description", "Родник")]),
        ])
        writer.ways([
            PBFWriter.Way(id: 10, refs: [1, 2], tags: [("highway", "track")]),
            PBFWriter.Way(id: 11, refs: [3, 4], tags: [("highway", "path")]),
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
        XCTAssertEqual(try read(kept).nodes.first { $0.id == 5 }?.tags["description"],
                       "Родник")

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
        XCTAssertFalse(Set(track).intersection(Set(joined)).isEmpty,
                       "the two ways still share nothing")
    }

    func testContourFilesAreFoldedIn() throws {
        let source = try makeExtract()
        let contours = path("contours.osm.pbf")
        let writer = try PBFWriter(to: contours)
        writer.header()
        writer.nodes((1...10).map {
            PBFWriter.Node(id: 20_000_000_000 + Int64($0), lat: 44.5, lon: 33.5, tags: [])
        })
        writer.ways([PBFWriter.Way(id: 5_000_000_001,
                                   refs: (1...10).map { 20_000_000_000 + Int64($0) },
                                   tags: [("contour", "elevation"), ("ele", "100")])])
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
