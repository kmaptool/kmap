import XCTest

@testable import kmap

/// Reading the water out of an extract: multipolygons with their islands, and closed ways
/// of their own.
final class WaterScanTests: XCTestCase {
    private var directory = URL(fileURLWithPath: "/tmp")

    override func setUpWithError() throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("kmap-water-scan-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    /// The lake's outer way carries `natural=water` itself, as mappers often leave it: it
    /// is the multipolygon's shore, and filling it again on its own would flood the island.
    func testAShoreThatIsAlsoTaggedAsWaterKeepsItsIsland() throws {
        let url = directory.appendingPathComponent("lake.osm.pbf")
        let writer = try PBFWriter(to: url)
        writer.header()
        let corners: [(Int64, Double, Double)] = [
            (1, 44.1, 34.1), (2, 44.1, 34.9), (3, 44.9, 34.9), (4, 44.9, 34.1),
            (5, 44.3, 34.3), (6, 44.3, 34.7), (7, 44.7, 34.7), (8, 44.7, 34.3)
        ]
        writer.nodes(corners.map { PBFWriter.Node(id: $0.0, lat: $0.1, lon: $0.2, tags: []) })
        writer.ways([
            PBFWriter.Way(id: 10, refs: [1, 2, 3, 4, 1], tags: [("natural", "water")]),
            PBFWriter.Way(id: 11, refs: [5, 6, 7, 8, 5], tags: [])
        ])
        writer.relations([
            PBFWriter.Relation(
                id: 100,
                members: [.init(kind: 1, ref: 10, role: "outer"), .init(kind: 1, ref: 11, role: "inner")],
                tags: [("type", "multipolygon"), ("natural", "water")]
            )
        ])
        try writer.finish()

        let bodies = try WaterScan.bodies(in: url, shouldStop: { false })
        let mask = try XCTUnwrap(WaterMask(cellAt: 44, 34, water: bodies))
        XCTAssertTrue(mask.isWater(lat: 44.2, lon: 34.5), "the lake")
        XCTAssertFalse(mask.isWater(lat: 44.5, lon: 34.5), "the island")
    }
}
