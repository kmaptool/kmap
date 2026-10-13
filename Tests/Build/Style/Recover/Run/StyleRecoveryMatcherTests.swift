import XCTest

@testable import kmap

/// The map's elements matched against the ground, extract by extract.
final class StyleRecoveryMatcherTests: XCTestCase {
    private func extract(_ name: String, villages: [Int64]) throws -> URL {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("matcher-run-\(UUID().uuidString.prefix(6))")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent(name)
        let writer = try PBFWriter(to: url)
        writer.header()
        writer.nodes(
            villages.map {
                PBFWriter.Node(id: $0, lat: 44.5 + Double($0) * 0.001, lon: 34.5, tags: [("place", "village")])
            }
        )
        try writer.finish()
        return url
    }

    /// The ground's meanings are counted once per object, however many extracts hold it.
    func testAnObjectInTwoExtractsIsCountedOnce() async throws {
        let first = try extract("a.osm.pbf", villages: [1, 2, 3])
        let second = try extract("b.osm.pbf", villages: [3, 4])
        let matcher = StyleRecovery.Matcher(
            dump: ElementDumper.Dump(),
            coarse: ElementDumper.Dump(),
            frame: BBox(minLon: 34, minLat: 44, maxLon: 35, maxLat: 45),
            several: true,
            log: Log(),
            progress: nil
        )
        try await matcher.read(first)
        try await matcher.read(second)
        XCTAssertEqual(matcher.groundTags["place=village"], 4)
        XCTAssertTrue(matcher.finish().codes.isEmpty, "no element of the map, no evidence")
    }

    /// A map's line drawn on a way's own vertices is matched to the way, over the cores.
    func testALineOnAWaysVerticesIsMatchedToTheWay() async throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("matcher-line-\(UUID().uuidString.prefix(6))")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("path.osm.pbf")
        var spots: [(id: Int64, lat: Double, lon: Double)] = []
        for n in 1...6 { spots.append((Int64(n), 44.5 + Double(n) * 0.001, 34.5 + Double(n) * 0.0007)) }
        let writer = try PBFWriter(to: url)
        writer.header()
        writer.nodes(spots.map { PBFWriter.Node(id: $0.id, lat: $0.lat, lon: $0.lon, tags: []) })
        writer.ways([PBFWriter.Way(id: 10, refs: spots.map { $0.id }, tags: [("highway", "path")])])
        try writer.finish()

        var dump = ElementDumper.Dump()
        dump.cells = spots.map { GarminGrid.cell(lat: $0.lat, lon: $0.lon) }
        dump.elements = [ElementDumper.Element(kind: .line, type: 0x30, from: 0, count: Int32(spots.count))]
        dump.resolutions = [24]
        let matcher = StyleRecovery.Matcher(
            dump: dump,
            coarse: ElementDumper.Dump(),
            frame: BBox(minLon: 34, minLat: 44, maxLon: 35, maxLat: 45),
            several: false,
            log: Log(),
            progress: nil
        )
        try await matcher.read(url)
        let evidence = matcher.finish()
        XCTAssertEqual(evidence.codes["L30"]?.sources[10]?["highway"], "path")
        XCTAssertEqual(evidence.codes["L30"]?.elements, 1)
    }
}
