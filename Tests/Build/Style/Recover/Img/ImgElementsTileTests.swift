import XCTest

@testable import kmap

/// The walk asks once a tile, before reading it: where a cancel lands when no element of
/// a tile lies near the ground.
final class ImgElementsTileTests: XCTestCase {
    private struct Stopped: Error {}

    func testATileIsAskedAboutBeforeItIsRead() throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("kmap-tiles-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        // Bodies that are no tile at all: read, they would throw a reading error.
        let junk = [UInt8](repeating: 1, count: 64)
        let img = try ImgFixture.container(
            [("63240001", "TRE", junk), ("63240001", "RGN", junk)],
            into: directory,
            signature: true
        )
        var tiles = 0, elements = 0
        XCTAssertThrowsError(
            try ImgElements.read(
                img: img,
                grounds: [ImgElements.Ground(BBox(minLon: -180, minLat: -90, maxLon: 180, maxLat: 90))],
                extendedAreasAndPoints: false,
                tick: { elements += 1 },
                tile: {
                    tiles += 1
                    throw Stopped()
                }
            ) { _, _, _ in }
        ) { XCTAssertTrue($0 is Stopped, "\($0)") }
        XCTAssertEqual(tiles, 1)
        XCTAssertEqual(elements, 0, "a tile is not counted as an element")
    }
}
