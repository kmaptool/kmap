import XCTest
@testable import kmap

/// Which failures a download picks itself up from, and the checksum that says it arrived
/// whole.
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

    // MARK: The checksum

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

    // MARK: A part and its file

    func testAPartKnowsItsLengthAndReadsItsProgressOffTheDisk() throws {
        // The file is the record: nothing else counts what a part has fetched.
        let url = directory.appendingPathComponent("region.osm.pbf.part2")
        let part = RangeSession.Part(index: 2, start: 100, end: 199, url: url)
        XCTAssertEqual(part.length, 100, "both ends are inside the range")
        XCTAssertEqual(part.written, 0, "no file yet")
        try Data(count: 40).write(to: url)
        XCTAssertEqual(part.written, 40)
    }

    func testCancellingIsRememberedAndRefusesFurtherWork() async {
        // A retry sleep can end after the cancel; a task made on a dead session never ends.
        let session = RangeSession(progress: DownloadProgress())
        XCTAssertFalse(session.isCancelled)
        session.cancel()
        XCTAssertTrue(session.isCancelled)
        let part = RangeSession.Part(index: 0, start: 0, end: 9,
                                     url: directory.appendingPathComponent("x.part0"))
        do {
            try await session.fetch(part, from: URL(string: "https://example.invalid/x")!, ranged: true)
            XCTFail("fetched on a cancelled session")
        } catch DownloadError.cancelled {
        } catch {
            XCTFail("\(error)")
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: part.url.path), "nothing was opened")
    }

    func testADownloaderIsCancelledThroughItsSession() {
        let downloader = Downloader(log: Log())
        XCTAssertFalse(downloader.wasCancelled)
        downloader.cancel()
        XCTAssertTrue(downloader.wasCancelled)
    }
}
