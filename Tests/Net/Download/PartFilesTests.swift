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
        try FileTools.write(Data(repeating: 7, count: bytes), to: url)
        return url
    }

    /// Parts of another copy of the same size are not joined to this one's: the date says
    /// which copy they are of. A record from before the date was kept still holds.
    func testPartsOfAnotherCopyOfTheSameSizeGo() throws {
        let files = PartFiles(destination: directory.appendingPathComponent("x.osm.pbf"))
        files.keepLayout(size: 100, count: 2, lastModified: "Mon, 05 Oct 2026 20:00:00 GMT")
        _ = try makeFile("x.osm.pbf.part0")
        files.keepLayout(size: 100, count: 2, lastModified: "Mon, 05 Oct 2026 20:00:00 GMT")
        XCTAssertTrue(FileTools.exists(files.part(0)), "the same copy resumes")
        files.keepLayout(size: 100, count: 2, lastModified: "Tue, 06 Oct 2026 20:00:00 GMT")
        XCTAssertFalse(FileTools.exists(files.part(0)), "another copy starts over")

        try FileTools.write("100/2\n", to: files.layout)
        _ = try makeFile("x.osm.pbf.part0")
        files.keepLayout(size: 100, count: 2, lastModified: "Tue, 06 Oct 2026 20:00:00 GMT")
        XCTAssertTrue(FileTools.exists(files.part(0)), "an earlier kmap's record of the same layout")
    }

    func testASinglePartThatCameUpShortIsRefusedNotInstalled() throws {
        // One connection, no ranges: the server can close early without an error, and
        // the short part must not be renamed into place as if whole.
        let part = try makeFile("region-b.osm.pbf.part0", bytes: 16)
        let files = PartFiles(destination: directory.appendingPathComponent("region-b.osm.pbf"))
        XCTAssertThrowsError(try files.assemble([part], expectedSize: 100))
        XCTAssertFalse(FileTools.exists(directory.appendingPathComponent("region-b.osm.pbf")))
    }

    func testASinglePartOfTheRightSizeIsMovedIntoPlace() throws {
        let part = try makeFile("region-c.osm.pbf.part0", bytes: 16)
        let files = PartFiles(destination: directory.appendingPathComponent("region-c.osm.pbf"))
        try files.assemble([part], expectedSize: 16)
        XCTAssertEqual(FileTools.size(of: directory.appendingPathComponent("region-c.osm.pbf")), 16)
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

    /// In a folder of the person's only kmap's own parts go, and none below its top.
    func testOnlyKmapsOwnPartsGoWhereAsked() throws {
        let later = Date().addingTimeInterval(30 * 24 * 3600)
        let ours = try makeFile("region-a.osm.pbf.part0", bytes: 10)
        let mine = try makeFile("video.mp4.part1", bytes: 10)
        let below = directory.appendingPathComponent("sub/region-b.osm.pbf.part0")
        try FileManager.default.createDirectory(
            at: below.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try FileTools.write("1234567890", to: below)
        let freed = PartFiles.sweepAbandoned(in: directory, now: later, topOnly: true) {
            CacheClearing.isOwn($0, in: .extracts)
        }
        XCTAssertEqual(freed, 10)
        XCTAssertFalse(FileTools.exists(ours))
        XCTAssertTrue(FileTools.exists(mine))
        XCTAssertTrue(FileTools.exists(below))
    }

    func testADownloadsTailIsNothingALayoutOrNumberedPart() {
        for tail in ["", ".layout", ".part0", ".part12"] {
            XCTAssertTrue(PartFiles.isDownloadTail(Substring(tail)), tail)
        }
        for tail in [".part", ".partx", ".layout.part0", ".part\u{0661}", ".bak", "part0"] {
            XCTAssertFalse(PartFiles.isDownloadTail(Substring(tail)), tail)
        }
    }
}
