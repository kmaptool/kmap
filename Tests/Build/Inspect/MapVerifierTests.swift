import XCTest
@testable import kmap

/// Checking a finished map. The failures covered are those that install cleanly and then do
/// not work: a tile missing the subfile that draws it, no routing graph, or a TYP numbered
/// for another family.
final class VerifyCommandTests: XCTestCase {

    private var directory = URL(fileURLWithPath: "/tmp")

    override func setUpWithError() throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("kmap-verify-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func body(_ n: Int = 64) -> [UInt8] { [UInt8](repeating: 1, count: n) }

    private func map(_ files: [(name: String, ext: String, body: [UInt8])],
                     signature: Bool = true) throws -> MapVerifier.Report {
        MapVerifier.verify(try ImgFixture.container(files, into: directory,
                                                    signature: signature))
    }

    private func detail(_ report: MapVerifier.Report, _ label: String) -> String? {
        report.findings.first { $0.label == label }?.detail
    }

    private func level(_ report: MapVerifier.Report, _ label: String) -> MapVerifier.Finding.Level? {
        report.findings.first { $0.label == label }?.level
    }

    /// A complete map: one routable tile carrying elevation, a search index, and a TYP
    /// numbered for the same family as the tile.
    private func wholeMap() -> [(name: String, ext: String, body: [UInt8])] {
        [("63240001", "TRE", body()), ("63240001", "RGN", body()),
         ("63240001", "LBL", body()), ("63240001", "NET", body()),
         ("63240001", "NOD", body()), ("63240001", "DEM", body()),
         ("00006324", "MDR", body()), ("00006324", "SRT", body()),
         ("MAPSTYLE", "TYP", ImgFixture.typBody(family: 6324, product: 1))]
    }

    // MARK: A map that is fine

    func testAWholeMapPassesWithNothingToReport() throws {
        let report = try map(wholeMap())
        XCTAssertFalse(report.failed)
        XCTAssertFalse(report.warned)
        XCTAssertEqual(level(report, "tiles"), .ok)
        XCTAssertEqual(level(report, "routing"), .ok)
        XCTAssertEqual(level(report, "DEM layer"), .ok)
        XCTAssertEqual(level(report, "search index"), .ok)
        XCTAssertEqual(level(report, "TYP"), .ok)
    }

    // MARK: Things that make it useless

    func testAFileThatIsNotThereFailsAndStopsThere() {
        let report = MapVerifier.verify(directory.appendingPathComponent("absent.img"))
        XCTAssertTrue(report.failed)
        XCTAssertEqual(report.findings.count, 1)
        XCTAssertEqual(detail(report, "file"), "not found")
    }

    func testSomethingThatIsNotAGarminMapFailsOnTheContainer() throws {
        let report = try map(wholeMap(), signature: false)
        XCTAssertTrue(report.failed)
        XCTAssertEqual(level(report, "container"), .fail)
        // No further check is reported for a file that cannot be opened.
        XCTAssertNil(level(report, "tiles"))
    }

    func testAMapWithNoTilesAtAllFails() throws {
        let report = try map([("00006324", "MDR", body())])
        XCTAssertTrue(report.failed)
        XCTAssertEqual(detail(report, "tiles"), "no map tiles — this map draws nothing")
    }

    func testATileMissingWhatDrawsItFails() throws {
        // A tile needs TRE, RGN and LBL together to appear at all.
        let report = try map([("63240001", "TRE", body()), ("63240001", "RGN", body()),
                              ("63240001", "LBL", body()),
                              ("63240002", "TRE", body()), ("63240002", "RGN", body())])
        XCTAssertTrue(report.failed)
        XCTAssertEqual(level(report, "tiles"), .fail)
        XCTAssertTrue(detail(report, "tiles")?.contains("1 of 2 incomplete") ?? false,
                      detail(report, "tiles") ?? "")
        XCTAssertTrue(detail(report, "tiles")?.contains("63240002") ?? false)
    }

    func testAStyleNumberedForAnotherFamilyIsAFailureNotAWarning() throws {
        // A device ignores a TYP numbered for another family and draws its own colours.
        var files = wholeMap()
        files[files.count - 1] = ("MAPSTYLE", "TYP",
                                  ImgFixture.typBody(family: 6308, product: 1))
        let report = try map(files)
        XCTAssertTrue(report.failed)
        XCTAssertEqual(level(report, "TYP"), .fail)
        XCTAssertTrue(detail(report, "TYP")?.contains("ignore the TYP") ?? false,
                      detail(report, "TYP") ?? "")
    }

    // MARK: Things worth saying but not fatal

    func testAMapThatCannotNavigateIsAWarning() throws {
        // A display-only map is valid, so the missing routing graph warns rather than fails.
        let report = try map([("63240001", "TRE", body()), ("63240001", "RGN", body()),
                              ("63240001", "LBL", body()), ("00006324", "MDR", body()),
                              ("MAPSTYLE", "TYP", ImgFixture.typBody(family: 6324, product: 1))])
        XCTAssertFalse(report.failed)
        XCTAssertTrue(report.warned)
        XCTAssertEqual(level(report, "routing"), .warn)
        XCTAssertEqual(level(report, "DEM layer"), .warn)
    }

    func testAMapWithNoSearchIndexIsAWarning() throws {
        var files = wholeMap()
        files.removeAll { $0.ext == "MDR" }
        let report = try map(files)
        XCTAssertEqual(level(report, "search index"), .warn)
        XCTAssertFalse(report.failed)
    }

    func testAnIndexWithoutItsSortTableIsAWarning() throws {
        // The SRT carries the sort order the index is searched under; without it the
        // device misfiles non-Latin names.
        var files = wholeMap()
        files.removeAll { $0.ext == "SRT" }
        let report = try map(files)
        XCTAssertEqual(level(report, "search index"), .warn)
        XCTAssertFalse(report.failed)
    }

    func testAMapWithNoStyleIsAWarningRatherThanAFailure() throws {
        // A device falls back to its own colours.
        var files = wholeMap()
        files.removeAll { $0.ext == "TYP" }
        let report = try map(files)
        XCTAssertEqual(level(report, "TYP"), .warn)
        XCTAssertFalse(report.failed)
    }

    func testPartlyRoutableIsReportedWithTheCount() throws {
        let report = try map([("63240001", "TRE", body()), ("63240001", "RGN", body()),
                              ("63240001", "LBL", body()), ("63240001", "NET", body()),
                              ("63240001", "NOD", body()),
                              ("63240002", "TRE", body()), ("63240002", "RGN", body()),
                              ("63240002", "LBL", body())])
        XCTAssertEqual(level(report, "routing"), .ok)
        XCTAssertEqual(detail(report, "routing"), "1/2 tile(s) routable")
    }
}
