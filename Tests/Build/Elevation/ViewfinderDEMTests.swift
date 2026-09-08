import XCTest
@testable import kmap

/// Which Viewfinder archive holds which degree tile. The index is derived from the
/// coverage page and shared byte for byte with pyhgtmap, so its rounding is kept as
/// pyhgtmap has it rather than corrected.
final class ViewfinderDEMTests: XCTestCase {

    private var directory = URL(fileURLWithPath: "/tmp")

    override func setUpWithError() throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("kmap-view-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    // MARK: What a finished tile looks like

    func testAFinishedTileIsKnownByItsSizeAlone() {
        // A `.hgt` is a bare grid with no header, so size alone separates a complete
        // download from a truncated one.
        XCTAssertEqual(ViewfinderDEM.expectedSize(1), 2 * 3601 * 3601)
        XCTAssertEqual(ViewfinderDEM.expectedSize(3), 2 * 1201 * 1201)
    }

    func testAShortOrMissingFileIsNotComplete() throws {
        let url = directory.appendingPathComponent("N44E033.hgt")
        XCTAssertFalse(ViewfinderDEM.isComplete(url, resolution: 3))
        try Data(count: 2 * 1201 * 1201 - 1).write(to: url)
        XCTAssertFalse(ViewfinderDEM.isComplete(url, resolution: 3))
        try Data(count: 2 * 1201 * 1201).write(to: url)
        XCTAssertTrue(ViewfinderDEM.isComplete(url, resolution: 3))
        // The same bytes are not a complete one-arc-second tile.
        XCTAssertFalse(ViewfinderDEM.isComplete(url, resolution: 1))
    }

    func testTheSourceAndDirectoryNamesAreTheOnesTheRestOfTheBuildLooksFor() {
        XCTAssertEqual(ViewfinderDEM.sourceID(1), "view1")
        XCTAssertEqual(ViewfinderDEM.directoryName(3), "VIEW3")
        XCTAssertEqual(ViewfinderDEM.cachedTile("N44E033", resolution: 1).lastPathComponent,
                       "N44E033.hgt")
        XCTAssertEqual(ViewfinderDEM.indexFile(3).lastPathComponent,
                       "viewfinderHgtIndex_3.txt")
    }

    func testTheIndexVersionsArePyhgtmapsOwn() {
        // Stamped into the file header; on a mismatch the shared index is discarded and
        // rebuilt from the coverage page.
        XCTAssertEqual(ViewfinderDEM.indexVersion(1), 2)
        XCTAssertEqual(ViewfinderDEM.indexVersion(3), 4)
    }

    // MARK: The index file

    func testAnIndexSurvivesBeingWrittenAndReadBack() throws {
        var index = ViewfinderDEM.Index()
        index.entries["https://viewfinderpanoramas.org/dem1/L32.zip"] = ["N44E033", "N44E034"]
        index.entries["https://viewfinderpanoramas.org/dem1/ANT-E.zip"] = ["S61E060"]
        let url = directory.appendingPathComponent("index.txt")
        try index.save(to: url, resolution: 1)

        let text = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(text.hasPrefix("# VIEW1 index file, VERSION=2\n"), text)
        XCTAssertEqual(ViewfinderDEM.Index.load(url)?.entries, index.entries)
    }

    func testLoadingRefusesAFileWithNoEntriesRatherThanReturningAnEmptyIndex() throws {
        // An empty index would read as "no archive covers anything" instead of prompting
        // a rebuild.
        let url = directory.appendingPathComponent("empty.txt")
        try "# VIEW1 index file, VERSION=2\n\n".write(to: url, atomically: true, encoding: .utf8)
        XCTAssertNil(ViewfinderDEM.Index.load(url))
        XCTAssertNil(ViewfinderDEM.Index.load(directory.appendingPathComponent("absent.txt")))
    }

    func testAnArchiveWithNoTilesIsKeptAsAnArchiveWithNoTiles() throws {
        // An archive known to hold no tiles must survive the round trip, or it is fetched
        // again on the next build.
        var index = ViewfinderDEM.Index()
        index.entries["https://viewfinderpanoramas.org/dem3/SA19.zip"] = []
        let url = directory.appendingPathComponent("sea.txt")
        try index.save(to: url, resolution: 3)
        XCTAssertEqual(ViewfinderDEM.Index.load(url)?.entries.keys.first,
                       "https://viewfinderpanoramas.org/dem3/SA19.zip")
        XCTAssertEqual(ViewfinderDEM.Index.load(url)?.entries.values.first, [])
    }

    func testTheArchivesClaimingATileComeBackInASettledOrder() {
        // Archives overlap, so several claim one degree; a settled order keeps which is
        // downloaded first repeatable.
        var index = ViewfinderDEM.Index()
        index.entries["https://x/L32.zip"] = ["N44E033"]
        index.entries["https://x/A32.zip"] = ["N44E033"]
        index.entries["https://x/Z99.zip"] = ["N10E010"]
        XCTAssertEqual(index.urls(for: "N44E033"), ["https://x/A32.zip", "https://x/L32.zip"])
        XCTAssertEqual(index.urls(for: "S99W099"), [])
    }

    // MARK: The coverage page

    func testTheCoveragePageIsReadTagByTagWhateverTheAttributeOrderIs() {
        // Hand-written HTML: quotes of either kind, attributes in any order, newlines
        // inside a tag.
        let html = """
        <html><body><map>
        <area shape="rect" coords="900,400,905,405" href="https://x/A.zip">
        <area href='https://x/B.zip' coords='905,400,910,405'>
        <area
             coords="910,400,915,405"
             href=https://x/C.zip>
        <area shape="rect" coords="920,400,925,405">
        </map></body></html>
        """
        let index = ViewfinderDEM.Index.parse(coveragePage: html)
        XCTAssertEqual(Set(index.entries.keys),
                       ["https://x/A.zip", "https://x/B.zip", "https://x/C.zip"])
        // The fourth has no href and stands for nothing.
        XCTAssertEqual(index.entries.count, 3)
        XCTAssertFalse(index.entries["https://x/A.zip"]!.isEmpty)
    }

    func testTheImageMapIsFivePixelsToTheDegree() {
        // 1800×900 pixels for 360°×180°, the centre being the equator at the meridian.
        XCTAssertEqual(ViewfinderDEM.innerAreas("900,445,905,450"), ["N00E000"])
        // Half-open in both directions: one degree east, still the row at the equator.
        XCTAssertEqual(ViewfinderDEM.innerAreas("905,445,910,450"), ["N00E001"])
    }

    func testARectangleCoveringSeveralDegreesNamesEveryOneOfThem() {
        let names = ViewfinderDEM.innerAreas("900,435,910,445")
        XCTAssertEqual(Set(names), ["N01E000", "N02E000", "N01E001", "N02E001"])
        XCTAssertEqual(names.count, 4)
    }

    func testARectangleWithoutFourNumbersNamesNothing() {
        XCTAssertEqual(ViewfinderDEM.innerAreas(""), [])
        XCTAssertEqual(ViewfinderDEM.innerAreas("900,400,905"), [])
        XCTAssertEqual(ViewfinderDEM.innerAreas("a,b,c,d"), [])
    }

    func testAnEmptyRectangleNamesNothingRatherThanOneTile() {
        // Degenerate areas exist on the page; a half-open range must stay half-open.
        XCTAssertEqual(ViewfinderDEM.innerAreas("900,450,900,450"), [])
    }

    func testTheSouthernHemisphereIsReadFromTheRectangleNotTheRow() {
        // pyhgtmap reads the rectangle's southern edge rather than the row named; kept so
        // cached indexes agree with freshly built ones.
        let south = ViewfinderDEM.innerAreas("900,455,905,460")
        XCTAssertEqual(south, ["S02E000"])
        let crossing = ViewfinderDEM.innerAreas("900,445,905,455")
        XCTAssertTrue(crossing.allSatisfy { $0.hasPrefix("S") },
                      "the quirk has changed: \(crossing)")
    }
}
