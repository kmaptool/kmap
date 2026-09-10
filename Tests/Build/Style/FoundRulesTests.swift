import XCTest
@testable import kmap

/// Rules kmap adds for meanings a foreign map draws and mkgmap's style does not emit.
///
/// Each is found by `kmap recover`, which reads a foreign map against the OSM data it was
/// built from. What is checked here is what makes such a rule safe to add.
final class FoundRulesTests: XCTestCase {

    private var everyRule: String {
        [StyleCatalog.foundPointRules,
         StyleCatalog.foundLineRules,
         StyleCatalog.foundPolygonRules].joined(separator: "\n")
    }

    /// Rule lines only, comments and blanks dropped.
    private func rules(_ text: String) -> [String] {
        text.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }
    }

    private func codes(_ text: String) -> [Int] {
        rules(text).compactMap { line in
            guard let at = line.range(of: "[0x") else { return nil }
            return Int(line[at.upperBound...].prefix(while: \.isHexDigit), radix: 16)
        }
    }

    /// A new code would need an entry in the TYP the person building the map imported; a code
    /// the style already emits is one that TYP already draws.
    func testEveryCodeIsOneTheStyleAlreadyDrawsSomethingWith() {
        let kin: [Int: String] = [
            0x6411: "mast and tower", 0x6415: "lighthouse", 0x0b00: "hamlet", 0x3003: "town hall",
            0x2f09: "marina and ferry pier", 0x2c08: "sports pitch", 0x2c02: "ruin and dig",
            0x18: "stream and drain", 0x17: "fence, wall, hedge, breakwater, park",
            0x25: "pedestrian area", 0x0e: "runway", 0x0c: "quarry and industry",
            0x05: "car park", 0x4f: "scrub", 0x13: "building",
        ]
        for code in codes(everyRule) {
            XCTAssertNotNil(kin[code],
                            "0x\(String(code, radix: 16)) is not a code this style already draws with")
        }
    }

    /// Garmin firmware may route along the line types in GType.isSpecialRoutableLineType, so
    /// a decoration wearing one would drag the router onto it.
    func testNoLineHereWearsATypeTheFirmwareMightRouteAlong() {
        let routable = Set(0x01...0x13).union([0x16, 0x1a, 0x1b, 0x2c, 0x2d, 0x2e, 0x2f])
        for code in codes(StyleCatalog.foundLineRules) {
            XCTAssertFalse(routable.contains(code),
                           "0x\(String(code, radix: 16)) is firmware-routable and this is not a road")
        }
    }

    /// The hide catalogue is generated from these lines, one entry per rule, so each rule
    /// must be readable on its own.
    func testEveryPointRuleCanBeHiddenOnItsOwn() {
        // `place` is never offered, so the place rules are the only ones absent.
        for line in rules(StyleCatalog.foundPointRules) where !line.hasPrefix("place=") {
            let parsed = HideableGenerator.rule(from: line)
            XCTAssertNotNil(parsed, "the hide catalogue cannot read: \(line)")
        }
    }

    /// A found rule is added after the general rule it stands behind, since an object
    /// usually matches both and the general rule is to answer first.
    func testTheyAreAddedAfterTheRulesTheyStandBehind() throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("found-\(UUID().uuidString.prefix(6))")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try "building=* & building!=no [0x13 resolution 24]\n\n<finalize>\n"
            .write(to: folder.appendingPathComponent("polygons"),
                   atomically: true, encoding: .utf8)

        let catalog = StyleCatalog(settings: SettingsStore(), toolchain: Toolchain(settings: SettingsStore()))
        try catalog.addFoundPolygonRules(in: folder, log: Log())
        let text = try String(contentsOf: folder.appendingPathComponent("polygons"),
                              encoding: .utf8)
        let building = try XCTUnwrap(text.range(of: "building=* & building!=no"))
        let church = try XCTUnwrap(text.range(of: "amenity=place_of_worship [0x13"))
        XCTAssertLessThan(building.lowerBound, church.lowerBound)
        // And before <finalize>: a rule after it never fires.
        let finalize = try XCTUnwrap(text.range(of: "<finalize>"))
        XCTAssertLessThan(church.lowerBound, finalize.lowerBound)
    }

    /// Adding them twice would put two rules in the file for every meaning here.
    func testAStyleThatAlreadyHasThemIsLeftAlone() throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("found-\(UUID().uuidString.prefix(6))")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try "waterway=stream | waterway=drain [0x18 resolution 22]\n"
            .write(to: folder.appendingPathComponent("lines"),
                   atomically: true, encoding: .utf8)

        let catalog = StyleCatalog(settings: SettingsStore(), toolchain: Toolchain(settings: SettingsStore()))
        try catalog.addFoundLineRules(in: folder, log: Log())
        let once = try String(contentsOf: folder.appendingPathComponent("lines"), encoding: .utf8)
        try catalog.addFoundLineRules(in: folder, log: Log())
        let twice = try String(contentsOf: folder.appendingPathComponent("lines"), encoding: .utf8)
        XCTAssertEqual(once, twice)
        XCTAssertEqual(twice.components(separatedBy: "waterway=ditch [0x18").count - 1, 1)
    }
}
