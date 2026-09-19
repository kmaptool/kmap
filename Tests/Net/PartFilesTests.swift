import XCTest

@testable import kmap

/// Clearing up after downloads that stopped.
final class PartFilesTests: XCTestCase {
    private var directory = URL(fileURLWithPath: "/tmp")

    override func setUpWithError() throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("kmap-net-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func makeFile(_ name: String, bytes: Int = 16) throws -> URL {
        let url = directory.appendingPathComponent(name)
        try Data(repeating: 7, count: bytes).write(to: url)
        return url
    }

    /// A part is a leftover once the whole file it belongs to exists.
    func testAPartIsClearedOnceItsFileHasArrivedWhole() throws {
        let whole = try makeFile("region-a.osm.pbf")
        CacheStamp(size: 16, lastModified: "now", md5: nil).write(besides: whole)
        let part = try makeFile("region-a.osm.pbf.part0", bytes: 100)
        let layout = try makeFile("region-a.osm.pbf.layout", bytes: 8)

        let freed = PartFiles.sweepAbandoned(in: directory)

        XCTAssertFalse(FileTools.exists(part))
        XCTAssertFalse(FileTools.exists(layout), "a layout goes with the last of its parts")
        XCTAssertTrue(FileTools.exists(whole), "the file itself is not a leftover")
        XCTAssertEqual(freed, 108)
    }

    /// A recent part with nothing finished behind it is a download still running.
    func testATodaysPartIsLeftAloneWhenNothingFinishedBehindIt() throws {
        let part = try makeFile("region-b.osm.pbf.part0", bytes: 100)
        XCTAssertEqual(PartFiles.sweepAbandoned(in: directory), 0)
        XCTAssertTrue(FileTools.exists(part))
    }

    /// The same part, old enough to be a leftover.
    func testAPartWithNothingBehindItIsClearedOnceItIsOldEnough() throws {
        let part = try makeFile("region-b.osm.pbf.part0", bytes: 100)
        let later = Date().addingTimeInterval(30 * 24 * 3600)
        XCTAssertEqual(PartFiles.sweepAbandoned(in: directory, now: later), 100)
        XCTAssertFalse(FileTools.exists(part))
    }

    /// The layout records how the parts were laid out, so it is kept while any part is.
    func testTheLayoutStaysWhileAnyOfItsPartsDo() throws {
        _ = try makeFile("region-c.osm.pbf.part0", bytes: 100)
        let kept = try makeFile("region-c.osm.pbf.part1", bytes: 100)
        let layout = try makeFile("region-c.osm.pbf.layout", bytes: 8)
        // Only part0 is old enough; part1 was touched just now.
        let old = Date().addingTimeInterval(-30 * 24 * 3600)
        try FileManager.default.setAttributes(
            [.modificationDate: old],
            ofItemAtPath: directory.appendingPathComponent("region-c.osm.pbf.part0").path
        )

        _ = PartFiles.sweepAbandoned(in: directory)

        XCTAssertFalse(FileTools.exists(directory.appendingPathComponent("region-c.osm.pbf.part0")))
        XCTAssertTrue(FileTools.exists(kept))
        XCTAssertTrue(FileTools.exists(layout))
    }

    func testNothingButPartsIsTouched() throws {
        let extract = try makeFile("region-a.osm.pbf")
        let stamp = try makeFile("region-a.osm.pbf.stamp")
        let odd = try makeFile("notes.partly")
        let alsoOdd = try makeFile("archive.part")
        XCTAssertEqual(
            PartFiles.sweepAbandoned(
                in: directory,
                now: Date().addingTimeInterval(365 * 24 * 3600)
            ),
            0
        )
        for url in [extract, stamp, odd, alsoOdd] { XCTAssertTrue(FileTools.exists(url), "\(url)") }
    }
}
