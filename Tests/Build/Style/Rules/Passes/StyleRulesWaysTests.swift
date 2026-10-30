import XCTest

@testable import kmap

/// The barrier rewrites: the split into groups, and the access labels that have to land
/// above it, since the split's type rules consume the barrier.
final class StyleRulesWaysTests: XCTestCase {
    private var directory: URL!
    private var catalog: StyleCatalog!

    /// The stock rule, as mkgmap ships it.
    private let stockBarrierRule = """
        barrier=bollard | barrier=bus_trap | barrier=gate | barrier=block | barrier=cycle_barrier |
            barrier=stile | barrier=kissing_gate | barrier=lift_gate | barrier=swing_gate
            {add name='${barrier|subst:"_=> "}'} [0x3200 resolution 24]
        """

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ways-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let settings = SettingsStore()
        catalog = StyleCatalog(settings: settings, toolchain: Toolchain(settings: settings))
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func writePoints(_ text: String) throws {
        try text.write(
            to: directory.appendingPathComponent("points"),
            atomically: true,
            encoding: .utf8
        )
    }

    private func points() throws -> String {
        try String(contentsOf: directory.appendingPathComponent("points"), encoding: .utf8)
    }

    // MARK: Barriers

    /// A reworded comment once left the access rules out of every base: the split wrote
    /// one note and the access rules looked for another, and only the log said so.
    func testTheAccessRulesLandAboveTheSplitBlock() throws {
        try writePoints(
            "amenity=bench [0x2f0b resolution 24]\n" + stockBarrierRule
                + "\nnatural=peak [0x6616 resolution 24]\n"
        )
        let log = Log()
        try catalog.splitBarrierRule(in: directory, log: log)
        try catalog.addBarrierAccessRules(in: directory, cyrillic: false, log: log)

        let text = try points()
        let access = try XCTUnwrap(text.range(of: "# --- kmap: barrier access"))
        let block = try XCTUnwrap(text.range(of: StyleCatalog.barrierBlockNote))
        XCTAssertLessThan(
            access.lowerBound,
            block.lowerBound,
            "below the block the type rules would consume the barrier first"
        )
        XCTAssertTrue(text.contains("barrier=gate & locked=yes"), "the labels themselves")
        XCTAssertFalse(
            log.snapshot().contains { $0.severity == .warn },
            "nothing to warn about"
        )
    }

    func testTheAccessRulesAreWrittenOnce() throws {
        try writePoints(stockBarrierRule + "\n")
        let log = Log()
        try catalog.splitBarrierRule(in: directory, log: log)
        try catalog.addBarrierAccessRules(in: directory, cyrillic: false, log: log)
        try catalog.addBarrierAccessRules(in: directory, cyrillic: true, log: log)
        let text = try points()
        XCTAssertEqual(
            text.components(separatedBy: "# --- kmap: barrier access").count,
            2,
            "a second pass leaves the first alone"
        )
    }

    func testAFileWithoutTheBlockIsSaidSoRatherThanGuessedAt() throws {
        try writePoints("natural=peak [0x6616 resolution 24]\n")
        let log = Log()
        try catalog.addBarrierAccessRules(in: directory, cyrillic: false, log: log)
        XCTAssertFalse(try points().contains("# --- kmap: barrier access"))
        XCTAssertTrue(
            log.snapshot().contains { $0.severity == .warn },
            "the log says the labels are missing"
        )
    }

    // MARK: Trails

    private func trailRules(cyrillic: Bool) throws -> [String] {
        let url = directory.appendingPathComponent("lines")
        try "highway=path [0x0e resolution 23]\n".write(to: url, atomically: true, encoding: .utf8)
        try catalog.addTrailWarningRules(in: directory, cyrillic: cyrillic, log: Log())
        return try String(contentsOf: url, encoding: .utf8).components(separatedBy: "\n")
    }

    /// A grade and a lost path share a label, above each alone.
    func testAGradeAndItsVisibilityShareALabel() throws {
        let lines = try trailRules(cyrillic: false)
        func at(_ text: String) throws -> Int { try XCTUnwrap(lines.firstIndex { $0.contains(text) }, text) }
        let both = try at("sac_scale=demanding_alpine_hiking & (trail_visibility=no")
        XCTAssertTrue(lines[both].hasSuffix("{ name '${name} (demanding alpine terrain T5, path disappears)' }"))
        let grade = try at("sac_scale=demanding_alpine_hiking & name!=* { name 'demanding alpine terrain T5' }")
        let lost = try XCTUnwrap(lines.firstIndex { $0.hasPrefix("(trail_visibility=no") })
        let ferrata = try at("via_ferrata_scale!=0 & name=*")
        XCTAssertLessThan(ferrata, both, "a via ferrata says so first")
        XCTAssertLessThan(both, grade)
        XCTAssertLessThan(grade, lost)
    }

    /// T1 and T2 say nothing: every park path would carry a label.
    func testAnEasyPathIsNotLabelled() throws {
        let text = try trailRules(cyrillic: false).joined(separator: "\n")
        XCTAssertFalse(text.contains("sac_scale=hiking"))
        XCTAssertFalse(text.contains("sac_scale=mountain_hiking"))
        let t6 = "sac_scale=difficult_alpine_hiking & name!=* { name 'difficult alpine terrain T6' }"
        XCTAssertTrue(text.contains(t6))
    }
}
