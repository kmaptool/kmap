import XCTest

@testable import kmap

/// An extract's ground, indexed.
final class GroundIndexTests: XCTestCase {
    private func extract() throws -> URL {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("ground-\(UUID().uuidString.prefix(6))")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("places.osm.pbf")
        let writer = try PBFWriter(to: url)
        writer.header()
        writer.nodes([PBFWriter.Node(id: 1, lat: 44.5, lon: 34.5, tags: [("place", "village")])])
        try writer.finish()
        return url
    }

    private let frame = BBox(minLon: 34, minLat: 44, maxLon: 35, maxLat: 45)

    func testTheTaggedObjectsInTheFrameAreIndexed() throws {
        XCTAssertEqual(try GroundIndex(extract: extract(), frame: frame).nodes.map(\.id), [1])
    }

    /// A map across 180 deg states its east edge past 180; the objects there have
    /// longitudes from -180 up.
    func testAFrameAcross180KeepsBothItsSides() throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("ground-\(UUID().uuidString.prefix(6))")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("seam.osm.pbf")
        let writer = try PBFWriter(to: url)
        writer.header()
        writer.nodes([
            PBFWriter.Node(id: 1, lat: -17, lon: 179, tags: [("place", "village")]),
            PBFWriter.Node(id: 2, lat: -17, lon: -179, tags: [("place", "village")]),
            PBFWriter.Node(id: 3, lat: -17, lon: -170, tags: [("place", "village")])
        ])
        try writer.finish()
        let seam = BBox(minLon: 177, minLat: -20, maxLon: 182, maxLat: -15)
        XCTAssertEqual(try GroundIndex(extract: url, frame: seam).nodes.map(\.id).sorted(), [1, 2])
    }

    /// A raised stop ends the reading before the first blob.
    func testARaisedStopEndsTheReading() throws {
        let url = try extract()
        let stop = StopFlag()
        stop.raise()
        XCTAssertThrowsError(try GroundIndex(extract: url, frame: frame, stop: stop)) {
            XCTAssertTrue($0 is CancellationError, "\($0)")
        }
    }
}
