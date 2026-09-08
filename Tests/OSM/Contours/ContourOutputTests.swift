import XCTest
@testable import kmap

/// Writing traced contours as a PBF for mkgmap to read.
///
/// Ids must stay inside the cell's own range, and a closed line must end on the node it
/// started from.
final class ContourOutputTests: XCTestCase {

    private var directory = URL(fileURLWithPath: "/tmp")

    override func setUpWithError() throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("kmap-contour-out-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private struct Collected: OSMSink {
        var nodes: [Int64] = []
        var ways: [(id: Int64, refs: [Int64], tags: [String: String])] = []

        mutating func node(id: Int64, lat: Double, lon: Double,
                           tags: ArraySlice<Int32>, block: OSMBlock) {
            nodes.append(id)
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

    @discardableResult
    private func write(_ lines: [Contours.Line], nodeStart: Int64 = 20_000_000_000,
                       wayStart: Int64 = 5_000_000_000,
                       major: Int = 100, medium: Int = 50) throws
        -> (counts: (nodes: Int, ways: Int), read: Collected) {
        let url = directory.appendingPathComponent("out.osm.pbf")
        let counts = try ContourOutput.write(lines, to: url, nodeStart: nodeStart,
                                             wayStart: wayStart, major: major, medium: medium)
        var collected = Collected()
        try PBFReader(url: url).read(into: &collected)
        return (counts, collected)
    }

    private func line(_ elevation: Int, _ points: [(Double, Double)],
                      closed: Bool = false) -> Contours.Line {
        Contours.Line(elevation: elevation,
                      points: points.map { (lat: $0.0, lon: $0.1) }, closed: closed)
    }

    // MARK: Shape

    func testAnOpenLineBecomesAWayOverItsOwnNodes() throws {
        let result = try write([line(100, [(44, 33), (44.1, 33.1), (44.2, 33.2)])])
        XCTAssertEqual(result.counts.nodes, 3)
        XCTAssertEqual(result.counts.ways, 1)
        XCTAssertEqual(result.read.nodes.count, 3)
        XCTAssertEqual(result.read.ways.count, 1)
        XCTAssertEqual(result.read.ways[0].refs, result.read.nodes)
    }

    func testAClosedLineEndsOnTheNodeItStartedFrom() throws {
        // A second node in the same place draws alike but leaves mkgmap an open ring.
        let result = try write([line(100, [(44, 33), (44.1, 33), (44.1, 33.1), (44, 33)],
                                     closed: true)])
        XCTAssertEqual(result.counts.nodes, 3)
        let refs = result.read.ways[0].refs
        XCTAssertEqual(refs.count, 4)
        XCTAssertEqual(refs.first, refs.last)
    }

    func testAShortClosedLineIsLeftAsItIs() throws {
        // Fewer than three points cannot be a ring; nothing is folded away.
        let result = try write([line(100, [(44, 33), (44.1, 33)], closed: true)])
        XCTAssertEqual(result.counts.nodes, 2)
        XCTAssertEqual(result.read.ways[0].refs.count, 2)
    }

    func testNothingInNothingOut() throws {
        let result = try write([])
        XCTAssertEqual(result.counts.nodes, 0)
        XCTAssertEqual(result.counts.ways, 0)
        XCTAssertTrue(result.read.ways.isEmpty)
    }

    // MARK: Ids

    func testIDsStartWhereTheCellWasToldToStart() throws {
        let result = try write([line(100, [(44, 33), (44.1, 33.1)])],
                               nodeStart: 21_000_000_000, wayStart: 6_000_000_000)
        XCTAssertEqual(result.read.nodes.first, 21_000_000_000)
        XCTAssertEqual(result.read.ways.first?.id, 6_000_000_000)
    }

    func testIDsAscendAcrossLinesSoTheSplitterCanWalkThem() throws {
        let result = try write([
            line(100, [(44, 33), (44.1, 33.1)]),
            line(120, [(44.2, 33.2), (44.3, 33.3), (44.4, 33.4)]),
        ])
        XCTAssertEqual(result.read.nodes, result.read.nodes.sorted())
        XCTAssertEqual(result.read.ways.map(\.id), result.read.ways.map(\.id).sorted())
        // No node is used by two different contours.
        XCTAssertEqual(Set(result.read.nodes).count, result.read.nodes.count)
    }

    func testEveryContourGetsItsOwnNodesEvenWhereTwoCross() throws {
        // Sharing a node between two contours would break the ascending numbering.
        let result = try write([
            line(100, [(44, 33), (44.5, 33.5)]),
            line(120, [(44, 33.5), (44.5, 33)]),
        ])
        XCTAssertEqual(result.counts.nodes, 4)
        XCTAssertEqual(Set(result.read.nodes).count, 4)
    }

    // MARK: Tags

    func testALineCarriesTheTagsTheStyleExpects() throws {
        let result = try write([line(120, [(44, 33), (44.1, 33.1)])])
        let tags = result.read.ways[0].tags
        XCTAssertEqual(tags["contour"], "elevation")
        XCTAssertEqual(tags["ele"], "120")
        XCTAssertNotNil(tags["contour_ext"])
    }

    func testTheHeavierLinesAreMarkedAsSuch() {
        // Every tenth line major, every fifth medium, at a 10 m step.
        XCTAssertEqual(ContourOutput.extra(100, major: 100, medium: 50), "elevation_major")
        XCTAssertEqual(ContourOutput.extra(50, major: 100, medium: 50), "elevation_medium")
        XCTAssertEqual(ContourOutput.extra(30, major: 100, medium: 50), "elevation_minor")
        XCTAssertEqual(ContourOutput.extra(0, major: 100, medium: 50), "elevation_major")
    }

    func testNegativeElevationsAreMarkedTheSameWayAsPositiveOnes() {
        XCTAssertEqual(ContourOutput.extra(-100, major: 100, medium: 50), "elevation_major")
        XCTAssertEqual(ContourOutput.extra(-50, major: 100, medium: 50), "elevation_medium")
        XCTAssertEqual(ContourOutput.extra(-30, major: 100, medium: 50), "elevation_minor")
    }

    func testAskingForNoHeavyLinesGivesNone() {
        XCTAssertEqual(ContourOutput.extra(100, major: 0, medium: 0), "elevation_minor")
    }

    func testANegativeElevationIsWrittenAsSuch() throws {
        let result = try write([line(-30, [(31.5, 35.5), (31.6, 35.6)])])
        XCTAssertEqual(result.read.ways[0].tags["ele"], "-30")
    }

    // MARK: Many lines

    func testAWholeTilesWorthOfContoursComesBackWhole() throws {
        // Past the batching inside the writer, in both nodes and ways.
        var lines: [Contours.Line] = []
        for i in 0..<3_000 {
            let lat = 44 + Double(i) * 1e-5
            lines.append(line(20 * (i % 50), [(lat, 33), (lat, 33.1), (lat, 33.2)]))
        }
        let result = try write(lines)
        XCTAssertEqual(result.counts.ways, 3_000)
        XCTAssertEqual(result.counts.nodes, 9_000)
        XCTAssertEqual(result.read.ways.count, 3_000)
        XCTAssertEqual(result.read.nodes.count, 9_000)
        XCTAssertEqual(result.read.nodes, result.read.nodes.sorted())
    }
}
