import XCTest
@testable import kmap

/// What the server said about an extract when it was cached: the cheap answer to "has
/// the source changed?". It must never call a changed source unchanged.
final class CacheStampTests: XCTestCase {

    private var directory = URL(fileURLWithPath: "/tmp")

    override func setUpWithError() throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("kmap-stamp-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private let modified = "Wed, 19 Aug 2026 23:14:11 GMT"

    /// `lastModified` is passed through as given; nil means the server said nothing.
    private func stamp(size: Int64 = 1000, md5: String? = "abc") -> CacheStamp {
        CacheStamp(size: size, lastModified: modified, md5: md5)
    }

    private func undated(size: Int64 = 1000) -> CacheStamp {
        CacheStamp(size: size, lastModified: nil, md5: "abc")
    }

    // MARK: Answering the cheap question

    func testTheSameSizeAndTheSameDateMeansTheSameExtract() {
        XCTAssertTrue(stamp().matches(size: 1000, lastModified: modified))
    }

    func testADifferentSizeIsADifferentExtract() {
        XCTAssertFalse(stamp().matches(size: 1001, lastModified: modified))
        XCTAssertFalse(stamp().matches(size: 999_999, lastModified: modified))
    }

    func testADifferentDateIsADifferentExtractEvenAtTheSameSize() {
        // Geofabrik republishes daily and an extract's size barely moves, so the date is
        // the half that catches it.
        XCTAssertFalse(stamp().matches(size: 1000,
                                       lastModified: "Thu, 20 Aug 2026 23:14:11 GMT"))
    }

    func testAServerThatSaysNothingIsNotTakenAsAgreement() {
        // With no date, nothing here can tell a new extract from the old one.
        XCTAssertFalse(stamp().matches(size: 1000, lastModified: nil))
        XCTAssertFalse(undated().matches(size: 1000, lastModified: modified))
        XCTAssertFalse(undated().matches(size: 1000, lastModified: nil))
    }

    func testASizeOfZeroIsNotAnAnswerEither() {
        // A HEAD with no Content-Length: zero against zero would call any file current.
        XCTAssertFalse(stamp(size: 0).matches(size: 0, lastModified: modified))
    }

    // MARK: Living beside the file

    func testAStampIsWrittenBesideItsFileAndReadBack() throws {
        let file = directory.appendingPathComponent("region.osm.pbf")
        try Data("extract".utf8).write(to: file)
        let written = stamp(size: 7, md5: "b4c8e5954933ffa5d884b03d41d84d8a")
        written.write(besides: file)

        XCTAssertEqual(CacheStamp.url(for: file).lastPathComponent, "region.osm.pbf.stamp")
        XCTAssertEqual(CacheStamp.read(besides: file), written)
    }

    func testNoStampReadsAsNoStampRatherThanAsAnEmptyOne() {
        // An extract cached before stamps existed has none, and falls through to the
        // checksum.
        let file = directory.appendingPathComponent("unstamped.osm.pbf")
        XCTAssertNil(CacheStamp.read(besides: file))
    }

    func testRubbishInPlaceOfAStampIsIgnored() throws {
        let file = directory.appendingPathComponent("region.osm.pbf")
        try Data("not json".utf8).write(to: CacheStamp.url(for: file))
        XCTAssertNil(CacheStamp.read(besides: file))
    }

    func testAStampGoesWhenTheExtractItDescribesGoes() throws {
        let file = directory.appendingPathComponent("region.osm.pbf")
        stamp().write(besides: file)
        XCTAssertNotNil(CacheStamp.read(besides: file))
        CacheStamp.remove(besides: file)
        XCTAssertNil(CacheStamp.read(besides: file))
        // And removing one that was never there is not an error.
        CacheStamp.remove(besides: file)
    }
}
