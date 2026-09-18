import XCTest
@testable import kmap

/// The passes that reword a style: the operator dropped from a named label, mkgmap's
/// default captions translated, and names for what OSM leaves unnamed.
final class StyleRulesLabelsPassesTests: XCTestCase {

    private var directory = URL(fileURLWithPath: "/tmp")

    override func setUpWithError() throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("kmap-labels-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory.appendingPathComponent("inc"),
                                                withIntermediateDirectories: true)
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

    private func isCyrillic(_ text: String) -> Bool {
        text.unicodeScalars.contains { (0x400...0x4FF).contains($0.value) }
    }

    // MARK: The operator

    private let stockName = "operator=* { name '${operator}' }\nbrand=${name}     { delete brand; }\n"

    func testANamedObjectLosesItsOperatorOnce() throws {
        try write(stockName, to: "inc/name")
        let styles = catalog
        try styles.dropOperatorFromNamedLabels(in: directory, log: Log(showing: .error))
        let once = try read("inc/name")
        XCTAssertTrue(once.contains("name=* { delete operator; }"))
        XCTAssertTrue(once.hasPrefix(stockName.dropLast()), "the stock lines stay, and stay first")
        try styles.dropOperatorFromNamedLabels(in: directory, log: Log(showing: .error))
        XCTAssertEqual(try read("inc/name"), once)
    }

    func testAChangedIncludeIsReportedAndLeftAlone() throws {
        let changed = "operator=* { name '${operator}' }\n"
        try write(changed, to: "inc/name")
        let log = Log(showing: .info)
        try catalog.dropOperatorFromNamedLabels(in: directory, log: log)
        XCTAssertEqual(try read("inc/name"), changed)
        XCTAssertEqual(log.snapshot().filter { $0.severity == .warn }.count, 1)
    }

    func testAStyleWithoutTheIncludeIsLeftAlone() throws {
        try catalog.dropOperatorFromNamedLabels(in: directory, log: Log(showing: .error))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: directory.appendingPathComponent("inc/name").path))
    }

    // MARK: Default captions

    /// One caption mkgmap writes itself, taken from the table kmap translates from.
    private func aDefaultCaption() throws -> String {
        let line = try XCTUnwrap(StyleAssets.defaultNameTranslations.split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty && !$0.hasPrefix("#") && $0.contains("|") })
        return String(line[..<(try XCTUnwrap(line.firstIndex(of: "|")))])
    }

    func testDefaultCaptionsAreTranslatedForACyrillicBuildOnly() throws {
        let caption = try aDefaultCaption()
        let stock = "amenity=x { add default_name '\(caption)' } [0x10 resolution 24]\n"
            + "amenity=y { add default_name 'Not In The Table' } [0x11 resolution 24]\n"
        try write(stock, to: "points")

        try catalog.translateDefaultNames(in: directory, cyrillic: false, log: Log(showing: .error))
        XCTAssertEqual(try read("points"), stock, "a Latin build keeps mkgmap's own wording")

        try catalog.translateDefaultNames(in: directory, cyrillic: true, log: Log(showing: .error))
        let text = try read("points")
        XCTAssertFalse(text.contains("default_name '\(caption)'"))
        XCTAssertTrue(isCyrillic(text))
        XCTAssertTrue(text.contains("'Not In The Table'"), "only the captions in the table")
        XCTAssertTrue(text.contains("[0x10 resolution 24]"), "the rule itself is untouched")
    }

    // MARK: Names for the unnamed

    func testRussianNamesGoFirstIntoEveryFileOfACyrillicBuildOnly() throws {
        let files = ["points", "polygons", "lines"]
        for file in files { try write("stock=yes [0x01 resolution 24]\n", to: file) }

        let styles = catalog
        try styles.addRussianLabels(in: directory, cyrillic: false, log: Log(showing: .error))
        for file in files { XCTAssertEqual(try read(file), "stock=yes [0x01 resolution 24]\n") }

        try styles.addRussianLabels(in: directory, cyrillic: true, log: Log(showing: .error))
        for file in files {
            let text = try read(file)
            XCTAssertTrue(text.hasPrefix("# --- kmap: names for things OSM leaves unnamed"), file)
            XCTAssertTrue(text.hasSuffix("stock=yes [0x01 resolution 24]\n"), file)
            XCTAssertTrue(isCyrillic(text), file)
        }
        let once = try read("points")
        try styles.addRussianLabels(in: directory, cyrillic: true, log: Log(showing: .error))
        XCTAssertEqual(try read("points"), once, "written once")
    }

    func testEveryNamingRuleIsActionOnlyAndSparesWhatHasAName() throws {
        // A type here would claim the object before the rule meant to draw it.
        try write("", to: "points")
        try catalog.addRussianLabels(in: directory, cyrillic: true, log: Log(showing: .error))
        let rules = try read("points").split(separator: "\n").filter { !$0.hasPrefix("#") }
        XCTAssertGreaterThan(rules.count, 10)
        for rule in rules {
            XCTAssertTrue(rule.contains("& name!=*"), String(rule))
            XCTAssertFalse(rule.contains("[0x"), String(rule))
        }
    }

    func testAValueWithASemicolonIsQuoted() throws {
        // Unquoted, the style parser reads the semicolon as a statement separator.
        try write("", to: "points")
        try catalog.addRussianLabels(in: directory, cyrillic: true, log: Log(showing: .error))
        for rule in try read("points").split(separator: "\n") where !rule.hasPrefix("#") {
            let condition = rule.components(separatedBy: " & name!=*")[0]
            if condition.contains(";") { XCTAssertTrue(condition.contains("='"), condition) }
        }
    }
}
