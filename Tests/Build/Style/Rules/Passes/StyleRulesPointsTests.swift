import XCTest

@testable import kmap

/// A mountain pass shows its `rtsa_scale` category, in the map's alphabet.
final class StyleRulesPointsTests: XCTestCase {
    private var directory: URL!
    private var catalog: StyleCatalog!

    /// The Cyrillic forms, from the words table: the sources stay ASCII.
    private let ru = StyleWords(cyrillic: true)
    private var a: String { ru("terrain.pass-a") }
    private var b: String { ru("terrain.pass-b") }
    private var none: String { ru("terrain.pass-none") }

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("points-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let settings = SettingsStore()
        catalog = StyleCatalog(settings: settings, toolchain: Toolchain(settings: settings))
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    /// Whether mkgmap's `~` takes the whole of `value`.
    private func matches(_ value: String, _ pattern: String) -> Bool {
        value.range(of: "^(\(pattern))$", options: .regularExpression) != nil
    }

    /// The label filter run over `value`, its substitutions in order.
    private func label(_ value: String, cyrillic: Bool) -> String {
        let text = StyleCatalog.passCategoryLabel(cyrillic: cyrillic)
        let body = text.dropFirst("${rtsa_scale|".count).dropLast()
        return body.split(separator: "|").reduce(value) { out, filter in
            let parts = filter.dropFirst("subst:".count).components(separatedBy: "~>")
            return out.replacingOccurrences(of: parts[0], with: parts[1], options: .regularExpression)
        }
    }

    /// The values a North Caucasus extract holds, in either alphabet.
    func testEveryCategoryTheExtractWritesIsRead() {
        let values = [
            none, "1\(a)", "1\(b)*", "2\(a)", "2\(b)-3\(a)", "\(none)-1\(a)", "3\(b)*", "\(none)*",
            "1A", "1B", "2a", "n/c", "nc", "1A\u{2013}1B", "1A - 1B", "1A/1B"
        ]
        for value in values {
            XCTAssertTrue(matches(value, StyleCatalog.passCategory), value)
        }
    }

    /// A doubt or a note in the value leaves the pass with its name alone.
    func testAnythingElseIsLeftOut() {
        for value in ["1\(b)?", "1\(a) winter", "4A", "1C", "yes", "2A-"] {
            XCTAssertFalse(matches(value, StyleCatalog.passCategory), value)
        }
    }

    func testTheCategoryIsWrittenInTheMapsAlphabet() {
        XCTAssertEqual(label("1B", cyrillic: true), "1\(b)")
        XCTAssertEqual(label("2a*", cyrillic: true), "2\(a)*")
        XCTAssertEqual(label("N/C", cyrillic: true), none)
        XCTAssertEqual(label("1\(b)", cyrillic: false), "1B")
        XCTAssertEqual(label("\(none)-1\(a)", cyrillic: false), "n/c-1A")
        XCTAssertEqual(label("3\(b)*", cyrillic: false), "3B*")
        XCTAssertEqual(label("nc", cyrillic: true), none)
        XCTAssertEqual(label("1a \u{2014} 1b", cyrillic: false), "1A-1B")
        XCTAssertEqual(label("1A / 1B*", cyrillic: false), "1A/1B*")
    }

    func testANameWithACategoryOfItsOwnKeepsIt() {
        XCTAssertTrue(matches("Sovy 2, 2863 (1\(a))", StyleCatalog.passNameCategory))
        XCTAssertTrue(matches("1\(b)?", StyleCatalog.passNameCategory))
        XCTAssertFalse(matches("Kara-Tyube", StyleCatalog.passNameCategory))
        XCTAssertFalse(matches("Sovy 2, 2863", StyleCatalog.passNameCategory))
        XCTAssertFalse(matches("Lincoln", StyleCatalog.passNameCategory), "nc only with its slash")
    }

    /// The category names a pass ahead of `inc/name` and leaves the typing to the pass rule.
    func testACategoryIsNamedAheadOfTheNameRules() throws {
        let url = directory.appendingPathComponent("points")
        let stock = "natural=peak [0x6616 resolution 24]\ninclude 'inc/name';\n"
        try stock.write(to: url, atomically: true, encoding: .utf8)
        try catalog.addPassCategoryRules(in: directory, cyrillic: false, log: Log())
        let text = try String(contentsOf: url, encoding: .utf8)
        let named = try XCTUnwrap(text.range(of: "{ name '${ref} ${name} ("))
        let alone = try XCTUnwrap(text.range(of: "{ name 'Pass ${ref} ${rtsa_scale|"))
        let include = try XCTUnwrap(text.range(of: "include 'inc/name'"))
        XCTAssertLessThan(named.lowerBound, alone.lowerBound)
        XCTAssertLessThan(alone.lowerBound, include.lowerBound)
        XCTAssertFalse(text.contains("0x6613"))
    }
}
