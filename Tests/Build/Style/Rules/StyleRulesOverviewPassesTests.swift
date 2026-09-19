import XCTest

@testable import kmap

/// The passes that take things off the map: ground cover off the far zoom, and the
/// features somebody chose to hide.
final class StyleRulesOverviewPassesTests: XCTestCase {
    private var directory = URL(fileURLWithPath: "/tmp")

    override func setUpWithError() throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("kmap-overview-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private var catalog: StyleCatalog {
        let settings = SettingsStore()
        return StyleCatalog(settings: settings, toolchain: Toolchain(settings: settings))
    }

    private func write(_ text: String, to name: String) throws {
        try text.write(to: directory.appendingPathComponent(name), atomically: true, encoding: .utf8)
    }

    private func read(_ name: String) throws -> String {
        try String(contentsOf: directory.appendingPathComponent(name), encoding: .utf8)
    }

    // MARK: The overview

    func testGroundCoverLeavesTheFarZoomAndWaterDoesNot() throws {
        let water = "natural=water [0x3c resolution 18]"
        try write(
            "natural=grassland [0x55 resolution 18]\nnatural=scrub [0x4f resolution 18]\n\(water)\n",
            to: "polygons"
        )
        let log = Log(showing: .info)
        try catalog.thinTheOverview(in: directory, cyrillic: false, log: log)
        let text = try read("polygons")
        XCTAssertTrue(text.contains("natural=grassland [0x55 resolution 19]"), "a wash moves one finer")
        XCTAssertTrue(
            text.contains("natural=scrub [0x4f resolution 22]"),
            "a drawn texture waits for the zoom the paths arrive at"
        )
        XCTAssertTrue(text.contains(water), "water bodies are untouched")
        XCTAssertFalse(log.snapshot().isEmpty, "what moved is said")
    }

    func testAStyleWithNothingToThinIsNotRewritten() throws {
        let stock = "natural=water [0x3c resolution 18]\n"
        try write(stock, to: "polygons")
        try catalog.thinTheOverview(in: directory, cyrillic: false, log: Log(showing: .error))
        XCTAssertEqual(try read("polygons"), stock)
    }

    func testClosedMilitaryGroundIsLiftedAndFacilitiesAreNot() {
        let rules = "landuse=military [0x04 resolution 19]\nmilitary=barracks [0x04 resolution 23]\n"
        let lifted = StyleCatalog.restrictedMilitary(in: rules)
        XCTAssertEqual(lifted.moved, 1)
        XCTAssertTrue(lifted.text.contains("landuse=military [0x04 resolution 18]"))
        XCTAssertTrue(lifted.text.contains("military=barracks [0x04 resolution 23]"), "a building is not a zone")
    }

    // MARK: Hiding

    /// A feature from the catalogue, with the file and the rule line it silences.
    private func aHideableFeature() throws -> (HideableFeature, file: String, old: String, new: String) {
        let feature = try XCTUnwrap(HideableFeature.all.first { !$0.substitutions.isEmpty })
        let first = feature.substitutions[0]
        return (feature, first.file, first.old, first.new)
    }

    func testAHiddenFeatureLosesItsTypeAndNothingElseChanges() throws {
        let (feature, file, old, new) = try aHideableFeature()
        let neighbour = "stock:neighbour=yes [0x01 resolution 24]"
        try write("\(neighbour)\n\(old)\n", to: file)
        let log = Log(showing: .info)
        try catalog.hideFeatures([feature.id], in: directory, log: log)
        let text = try read(file)
        XCTAssertFalse(text.contains(old))
        XCTAssertTrue(text.contains(new))
        XCTAssertTrue(text.contains(neighbour))
        XCTAssertTrue(log.snapshot().filter { $0.severity == .warn }.isEmpty)
    }

    func testARuleThatHasMovedIsReportedByTheFeaturesName() throws {
        let (feature, file, _, _) = try aHideableFeature()
        let stock = "stock:neighbour=yes [0x01 resolution 24]\n"
        try write(stock, to: file)
        let log = Log(showing: .info)
        try catalog.hideFeatures([feature.id], in: directory, log: log)
        XCTAssertEqual(try read(file), stock)
        let warnings = log.snapshot().filter { $0.severity == .warn }
        XCTAssertEqual(warnings.count, 1)
        XCTAssertTrue(warnings[0].text.contains(feature.name))
    }

    func testNothingChosenOrNothingKnownHidesNothing() throws {
        let stock = "a=b [0x01 resolution 24]\n"
        for file in ["points", "lines", "polygons"] { try write(stock, to: file) }
        let log = Log(showing: .info)
        try catalog.hideFeatures([], in: directory, log: log)
        try catalog.hideFeatures(["no-such-feature"], in: directory, log: log)
        for file in ["points", "lines", "polygons"] { XCTAssertEqual(try read(file), stock) }
        XCTAssertTrue(log.snapshot().isEmpty)
    }
}
