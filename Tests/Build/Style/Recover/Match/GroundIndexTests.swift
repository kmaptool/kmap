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
