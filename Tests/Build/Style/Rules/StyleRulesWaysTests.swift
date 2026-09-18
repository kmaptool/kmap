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
        try text.write(to: directory.appendingPathComponent("points"), atomically: true,
                       encoding: .utf8)
    }

    private func points() throws -> String {
        try String(contentsOf: directory.appendingPathComponent("points"), encoding: .utf8)
    }

    // MARK: Barriers

    /// A reworded comment once left the access rules out of every base: the split wrote
    /// one note and the access rules looked for another, and only the log said so.
    func testTheAccessRulesLandAboveTheSplitBlock() throws {
        try writePoints("amenity=bench [0x2f0b resolution 24]\n" + stockBarrierRule
                        + "\nnatural=peak [0x6616 resolution 24]\n")
        let log = Log()
        try catalog.splitBarrierRule(in: directory, log: log)
        try catalog.addBarrierAccessRules(in: directory, cyrillic: false, log: log)

        let text = try points()
        let access = try XCTUnwrap(text.range(of: "# --- kmap: barrier access"))
        let block = try XCTUnwrap(text.range(of: StyleCatalog.barrierBlockNote))
        XCTAssertLessThan(access.lowerBound, block.lowerBound,
                          "below the block the type rules would consume the barrier first")
        XCTAssertTrue(text.contains("barrier=gate & locked=yes"), "the labels themselves")
        XCTAssertFalse(log.snapshot().contains { $0.severity == .warn },
                       "nothing to warn about")
    }

    func testTheAccessRulesAreWrittenOnce() throws {
        try writePoints(stockBarrierRule + "\n")
        let log = Log()
        try catalog.splitBarrierRule(in: directory, log: log)
        try catalog.addBarrierAccessRules(in: directory, cyrillic: false, log: log)
        try catalog.addBarrierAccessRules(in: directory, cyrillic: true, log: log)
        let text = try points()
        XCTAssertEqual(text.components(separatedBy: "# --- kmap: barrier access").count, 2,
                       "a second pass leaves the first alone")
    }

    func testAFileWithoutTheBlockIsSaidSoRatherThanGuessedAt() throws {
        try writePoints("natural=peak [0x6616 resolution 24]\n")
        let log = Log()
        try catalog.addBarrierAccessRules(in: directory, cyrillic: false, log: log)
        XCTAssertFalse(try points().contains("# --- kmap: barrier access"))
        XCTAssertTrue(log.snapshot().contains { $0.severity == .warn },
                      "the log says the labels are missing")
    }
}
