import XCTest
@testable import kmap

/// Telling each barrier node which kind of way it stands on.
///
/// An OSM node carries no reference to the ways containing it, so mkgmap cannot classify a
/// gate on its own. The scan supplies that fact to the style.
final class BarrierScanTests: XCTestCase {

    private var directory = URL(fileURLWithPath: "/tmp")

    override func setUpWithError() throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("kmap-barriers-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    /// Writes an extract of tagged nodes and the ways over them, and returns the classes.
    private func classify(nodes: [(id: Int64, tags: [(String, String)])],
                          ways: [(id: Int64, refs: [Int64], tags: [(String, String)])])
        throws -> [Int64: String] {
        let url = directory.appendingPathComponent("in.osm.pbf")
        let writer = try PBFWriter(to: url)
        writer.header()
        writer.nodes(nodes.map {
            PBFWriter.Node(id: $0.id, lat: 44.5, lon: 33.5, tags: $0.tags)
        })
        if !ways.isEmpty {
            writer.ways(ways.map { PBFWriter.Way(id: $0.id, refs: $0.refs, tags: $0.tags) })
        }
        try writer.finish()
        return try BarrierScan.classify(url)
    }

    private let gate: [(String, String)] = [("barrier", "gate")]

    func testAGateOnAPathIsAPathGate() throws {
        let result = try classify(nodes: [(1, gate), (2, [])],
                                  ways: [(10, [1, 2], [("highway", "track")])])
        XCTAssertEqual(result[1], "path")
        XCTAssertNil(result[2])
    }

    func testEachClassOfWayIsToldApart() throws {
        for (highway, expected) in [("footway", "path"), ("steps", "path"),
                                    ("service", "minor"), ("residential", "minor"),
                                    ("primary", "major"), ("motorway", "major"),
                                    ("tertiary", "major")] {
            let result = try classify(nodes: [(1, gate), (2, [])],
                                      ways: [(10, [1, 2], [("highway", highway)])])
            XCTAssertEqual(result[1], expected, highway)
        }
    }

    func testAGateSetIntoAFenceIsAFrontGate() throws {
        // A gate on a fence or a wall and on no road is a boundary, not a way through.
        for barrier in ["fence", "wall", "hedge", "retaining_wall", "city_wall", "guard_rail"] {
            let result = try classify(nodes: [(1, gate), (2, [])],
                                      ways: [(10, [1, 2], [("barrier", barrier)])])
            XCTAssertEqual(result[1], "fence", barrier)
        }
    }

    func testAGateOnNothingAtAllIsStillReported() throws {
        // `none` is an answer: silence would leave the style with no rule to apply.
        let result = try classify(nodes: [(1, gate)], ways: [])
        XCTAssertEqual(result[1], "none")
    }

    func testARoadWinsOverTheFenceTheGateIsAlsoPartOf() throws {
        let result = try classify(nodes: [(1, gate), (2, []), (3, [])],
                                  ways: [(10, [1, 2], [("barrier", "fence")]),
                                         (11, [1, 3], [("highway", "service")])])
        XCTAssertEqual(result[1], "minor")
    }

    func testTheWayThatMattersMostWinsHoweverTheyAreOrdered() throws {
        // path beats minor beats major beats fence, whatever order the ways arrive in.
        let result = try classify(nodes: [(1, gate), (2, []), (3, [])],
                                  ways: [(10, [1, 2], [("highway", "primary")]),
                                         (11, [1, 3], [("highway", "path")])])
        XCTAssertEqual(result[1], "path")

        let other = try classify(nodes: [(1, gate), (2, []), (3, [])],
                                 ways: [(10, [1, 2], [("highway", "path")]),
                                        (11, [1, 3], [("highway", "primary")])])
        XCTAssertEqual(other[1], "path")
    }

    func testEveryKindOfBarrierNodeIsCounted() throws {
        for kind in ["gate", "lift_gate", "swing_gate", "kissing_gate", "bollard",
                     "block", "cycle_barrier", "stile", "bus_trap", "chain", "gate_lock"] {
            let result = try classify(nodes: [(1, [("barrier", kind)])], ways: [])
            XCTAssertEqual(result[1], "none", kind)
        }
    }

    func testSomethingThatIsNotABarrierIsNotCounted() throws {
        let result = try classify(nodes: [(1, [("barrier", "turnstile")]),
                                          (2, [("highway", "crossing")]),
                                          (3, [])], ways: [])
        XCTAssertTrue(result.isEmpty)
    }

    func testANodeOfAWayThatIsNeitherRoadNorFenceIsLeftAlone() throws {
        let result = try classify(nodes: [(1, gate), (2, [])],
                                  ways: [(10, [1, 2], [("landuse", "meadow")])])
        XCTAssertEqual(result[1], "none")
    }

    func testManyNodesAndWaysAcrossManyBlocks() throws {
        // More blocks than the reader batches, with the barriers scattered through them.
        var nodes: [(id: Int64, tags: [(String, String)])] = []
        var ways: [(id: Int64, refs: [Int64], tags: [(String, String)])] = []
        for i in Int64(1)...20_000 {
            nodes.append((i, i % 100 == 0 ? gate : []))
        }
        for i in Int64(0)..<2_000 {
            ways.append((30_000 + i, [i * 10 + 1, i * 10 + 2],
                         [("highway", i % 2 == 0 ? "track" : "primary")]))
        }
        let result = try classify(nodes: nodes, ways: ways)
        XCTAssertEqual(result.count, 200)
        // Whatever way a barrier lands on, it gets one of the five answers.
        XCTAssertTrue(result.values.allSatisfy {
            ["none", "path", "minor", "major", "fence"].contains($0)
        })
    }

    func testTheFilterNeverHidesARealBarrier() throws {
        // The bitmap in front of the set may answer false positive, never false negative.
        var nodes: [(id: Int64, tags: [(String, String)])] = []
        var refs: [Int64] = []
        for i in Int64(1)...5_000 {
            nodes.append((i * 7, gate))
            refs.append(i * 7)
        }
        let result = try classify(nodes: nodes,
                                  ways: [(1, refs, [("highway", "track")])])
        XCTAssertEqual(result.count, 5_000)
        XCTAssertTrue(result.values.allSatisfy { $0 == "path" })
    }
}
