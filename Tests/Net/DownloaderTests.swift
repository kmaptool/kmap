import XCTest
@testable import kmap

/// The progress a download is watched through, and the checksum that says it arrived
/// whole. Several connections write into their own ranges of one file, and the counters
/// are read from the render loop while the network writes them.
final class DownloaderTests: XCTestCase {

    private var directory = URL(fileURLWithPath: "/tmp")

    override func setUpWithError() throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("kmap-net-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    // MARK: Progress

    func testNothingIsKnownBeforeTheSizeIs() {
        // The screen reads these before the first response arrives.
        let progress = DownloadProgress()
        XCTAssertEqual(progress.total, 0)
        XCTAssertEqual(progress.received, 0)
        XCTAssertEqual(progress.fraction, 0)
        XCTAssertEqual(progress.rate, 0)
        XCTAssertEqual(progress.eta, .infinity)
        XCTAssertTrue(progress.partFractions.isEmpty)
        XCTAssertFalse(progress.stage.isEmpty)
    }

    func testEachConnectionCountsIntoTheWholeAndIntoItsOwnBar() {
        let progress = DownloadProgress()
        progress.begin(total: 1000, partTotals: [400, 600], alreadyOnDisk: 0)
        progress.advance(part: 0, by: 200)
        progress.advance(part: 1, by: 300)
        XCTAssertEqual(progress.received, 500)
        XCTAssertEqual(progress.fraction, 0.5)
        XCTAssertEqual(progress.partFractions, [0.5, 0.5])
    }

    func testAPartOutsideTheRangeIsIgnoredRatherThanCrashing() {
        // The delegate is called back per task, and a cancelled download can still deliver.
        let progress = DownloadProgress()
        progress.begin(total: 100, partTotals: [100], alreadyOnDisk: 0)
        progress.advance(part: 7, by: 50)
        progress.seedPart(7, bytes: 50)
        XCTAssertEqual(progress.received, 0)
    }

    func testWhatIsAlreadyOnDiskCountsAsReceivedButNotAsSpeed() {
        // Otherwise a resumed download reports an impossible rate for its first moment.
        let progress = DownloadProgress()
        progress.begin(total: 1000, partTotals: [1000], alreadyOnDisk: 900)
        XCTAssertEqual(progress.received, 900)
        XCTAssertEqual(progress.fraction, 0.9)
        XCTAssertEqual(progress.rate, 0)
    }

    func testTheRateIsNotGuessedAtFromTheFirstInstant() {
        // The rate takes half a second of samples before it says anything.
        let progress = DownloadProgress()
        progress.begin(total: 1_000_000, partTotals: [1_000_000], alreadyOnDisk: 0)
        progress.advance(part: 0, by: 100_000)
        XCTAssertEqual(progress.rate, 0)
        XCTAssertEqual(progress.eta, .infinity)
    }

    func testTheCountersHoldUpUnderEveryConnectionAtOnce() {
        let progress = DownloadProgress()
        let parts = 8
        progress.begin(total: Int64(parts * 1000),
                       partTotals: Array(repeating: 1000, count: parts), alreadyOnDisk: 0)
        DispatchQueue.concurrentPerform(iterations: parts) { part in
            for _ in 0..<1000 { progress.advance(part: part, by: 1) }
        }
        XCTAssertEqual(progress.received, Int64(parts * 1000))
        XCTAssertEqual(progress.fraction, 1)
        XCTAssertEqual(progress.partFractions, Array(repeating: 1, count: parts))
    }

    func testStartingAgainForgetsTheLastDownload() {
        let progress = DownloadProgress()
        progress.begin(total: 100, partTotals: [100], alreadyOnDisk: 0)
        progress.advance(part: 0, by: 100)
        progress.begin(total: 500, partTotals: [200, 300], alreadyOnDisk: 0)
        XCTAssertEqual(progress.received, 0)
        XCTAssertEqual(progress.total, 500)
        XCTAssertEqual(progress.partFractions, [0, 0])
    }

    // MARK: The checksum

    // MARK: Clearing up after downloads that stopped

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

        let freed = Downloader.sweepAbandonedParts(in: directory)

        XCTAssertFalse(FileTools.exists(part))
        XCTAssertFalse(FileTools.exists(layout), "a layout goes with the last of its parts")
        XCTAssertTrue(FileTools.exists(whole), "the file itself is not a leftover")
        XCTAssertEqual(freed, 108)
    }

    /// A recent part with nothing finished behind it is a download still running.
    func testATodaysPartIsLeftAloneWhenNothingFinishedBehindIt() throws {
        let part = try makeFile("region-b.osm.pbf.part0", bytes: 100)
        XCTAssertEqual(Downloader.sweepAbandonedParts(in: directory), 0)
        XCTAssertTrue(FileTools.exists(part))
    }

    /// The same part, old enough to be a leftover.
    func testAPartWithNothingBehindItIsClearedOnceItIsOldEnough() throws {
        let part = try makeFile("region-b.osm.pbf.part0", bytes: 100)
        let later = Date().addingTimeInterval(30 * 24 * 3600)
        XCTAssertEqual(Downloader.sweepAbandonedParts(in: directory, now: later), 100)
        XCTAssertFalse(FileTools.exists(part))
    }

    /// The layout records how the parts were laid out, so it is kept while any part is.
    func testTheLayoutStaysWhileAnyOfItsPartsDo() throws {
        _ = try makeFile("region-c.osm.pbf.part0", bytes: 100)
        let kept = try makeFile("region-c.osm.pbf.part1", bytes: 100)
        let layout = try makeFile("region-c.osm.pbf.layout", bytes: 8)
        // Only part0 is old enough; part1 was touched just now.
        let old = Date().addingTimeInterval(-30 * 24 * 3600)
        try FileManager.default.setAttributes([.modificationDate: old],
            ofItemAtPath: directory.appendingPathComponent("region-c.osm.pbf.part0").path)

        _ = Downloader.sweepAbandonedParts(in: directory)

        XCTAssertFalse(FileTools.exists(directory.appendingPathComponent("region-c.osm.pbf.part0")))
        XCTAssertTrue(FileTools.exists(kept))
        XCTAssertTrue(FileTools.exists(layout))
    }

    func testNothingButPartsIsTouched() throws {
        let extract = try makeFile("region-a.osm.pbf")
        let stamp = try makeFile("region-a.osm.pbf.stamp")
        let odd = try makeFile("notes.partly")
        let alsoOdd = try makeFile("archive.part")
        XCTAssertEqual(Downloader.sweepAbandonedParts(
            in: directory, now: Date().addingTimeInterval(365 * 24 * 3600)), 0)
        for url in [extract, stamp, odd, alsoOdd] { XCTAssertTrue(FileTools.exists(url), "\(url)") }
    }

    // MARK: Picking a part up again

    /// A transport failure is worth another try; a definite answer from the server is not.
    func testADroppedConnectionIsWorthAnotherTryAndAMissingFileIsNot() {
        for code: URLError.Code in [.timedOut, .networkConnectionLost, .cannotConnectToHost,
                                    .cannotFindHost, .dnsLookupFailed, .notConnectedToInternet,
                                    .resourceUnavailable, .badServerResponse, .zeroByteResource] {
            XCTAssertTrue(Downloader.worthRetrying(URLError(code)), "\(code)")
        }
        for code: URLError.Code in [.cancelled, .unsupportedURL, .badURL, .userAuthenticationRequired] {
            XCTAssertFalse(Downloader.worthRetrying(URLError(code)), "\(code)")
        }
    }

    /// A 5xx is the server falling over; a 4xx is an answer.
    func testAServerErrorIsWorthAnotherTryAndAClientErrorIsNot() {
        for code in [500, 502, 503, 504] {
            XCTAssertTrue(Downloader.worthRetrying(DownloadError.badStatus(code)), "\(code)")
        }
        for code in [400, 401, 403, 404, 410] {
            XCTAssertFalse(Downloader.worthRetrying(DownloadError.badStatus(code)), "\(code)")
        }
    }

    func testEverythingThatIsNotTheNetworkIsLeftAlone() {
        XCTAssertFalse(Downloader.worthRetrying(DownloadError.io("no space left")))
        XCTAssertFalse(Downloader.worthRetrying(DownloadError.cancelled))
        XCTAssertFalse(Downloader.worthRetrying(CocoaError(.fileNoSuchFile)))
    }

    func testTheChecksumIsTheOneEveryOtherToolReports() throws {
        // Compared against what Geofabrik publishes: lowercase hex of the file's MD5.
        let url = directory.appendingPathComponent("body")
        try Data("The quick brown fox jumps over the lazy dog".utf8).write(to: url)
        XCTAssertEqual(try Downloader.md5(of: url), "9e107d9d372bb6826bd81d3542a419d6")

        let empty = directory.appendingPathComponent("empty")
        try Data().write(to: empty)
        XCTAssertEqual(try Downloader.md5(of: empty), "d41d8cd98f00b204e9800998ecf8427e")
    }

    func testAFileLargerThanOneReadIsHashedWhole() throws {
        // Read in 8 MB blocks; a hash stopping at the first block would pass a truncation.
        let url = directory.appendingPathComponent("big")
        var body = Data(count: 8 * 1024 * 1024)
        body.append(Data("tail".utf8))
        try body.write(to: url)
        let whole = try Downloader.md5(of: url)

        let short = directory.appendingPathComponent("short")
        try Data(count: 8 * 1024 * 1024).write(to: short)
        XCTAssertNotEqual(whole, try Downloader.md5(of: short))
    }

    func testHashingReportsHowFarItHasGot() throws {
        let url = directory.appendingPathComponent("body")
        try Data(count: 20 * 1024 * 1024).write(to: url)
        var reported: [Double] = []
        _ = try Downloader.md5(of: url) { reported.append($0) }
        XCTAssertFalse(reported.isEmpty)
        XCTAssertEqual(reported.last ?? 0, 1, accuracy: 1e-9)
        XCTAssertEqual(reported, reported.sorted(), "the fraction went backwards")
    }

    func testHashingSomethingThatIsNotThereThrowsRatherThanReturningAHash() {
        XCTAssertThrowsError(try Downloader.md5(of: directory.appendingPathComponent("absent")))
    }
}
