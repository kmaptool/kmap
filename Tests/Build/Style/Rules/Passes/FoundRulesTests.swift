import XCTest

@testable import kmap

/// Rules kmap adds for meanings a foreign map draws and mkgmap's style does not emit.
///
/// Each is found by `kmap recover`, which reads a foreign map against the OSM data it was
/// built from. What is checked here is what makes such a rule safe to add.
final class FoundRulesTests: XCTestCase {
    private var everyRule: String {
        [
            StyleCatalog.foundPointRules,
            StyleCatalog.foundLineRules,
            StyleCatalog.foundWaterwayRules,
            StyleCatalog.foundPolygonRules
        ].joined(separator: "\n") + "\n" + StyleCatalog.foundAheadOfEvery.map(\.rules).joined(separator: "\n")
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
            0x2f09: "marina and ferry pier", 0x2c08: "sports pitch", 0x2c02: "museum and ruin",
            0x18: "stream", 0x26: "stream that runs dry", 0x17: "fence, wall, breakwater, park",
            0x25: "pedestrian area", 0x0e: "runway", 0x0c: "industry",
            0x05: "car park", 0x4f: "scrub"
        ]
        for code in codes(everyRule) {
            XCTAssertNotNil(
                kin[code],
                "0x\(String(code, radix: 16)) is not a code this style already draws with"
            )
        }
    }

    /// Garmin firmware may route along the line types in GType.isSpecialRoutableLineType, so
    /// a decoration wearing one would drag the router onto it.
    func testNoLineHereWearsATypeTheFirmwareMightRouteAlong() {
        let routable = Set(0x01...0x13).union([0x16, 0x1a, 0x1b, 0x2c, 0x2d, 0x2e, 0x2f])
        for code in codes(StyleCatalog.foundLineRules + "\n" + StyleCatalog.foundWaterwayRules) {
            XCTAssertFalse(
                routable.contains(code),
                "0x\(String(code, radix: 16)) is firmware-routable and this is not a road"
            )
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

    private func polygons(after stock: String) throws -> String {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("found-\(UUID().uuidString.prefix(6))")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("polygons")
        try stock.write(to: file, atomically: true, encoding: .utf8)
        let catalog = StyleCatalog(settings: SettingsStore(), toolchain: Toolchain(settings: SettingsStore()))
        try catalog.addFoundPolygonRules(in: folder, log: Log())
        return try String(contentsOf: file, encoding: .utf8)
    }

    /// A found rule is added after the stock rules, which answer first for an object
    /// that matches both, and before `<finalize>`: a rule after it never fires.
    func testTheyAreAddedAfterTheStockRules() throws {
        let text = try polygons(after: "building=* & building!=no [0x13 resolution 24]\n\n<finalize>\n")
        let building = try XCTUnwrap(text.range(of: "building=* & building!=no"))
        let finalize = try XCTUnwrap(text.range(of: "<finalize>"))
        for rule in ["aeroway=apron [0x0e", "tourism=picnic_site [0x17", "man_made=pier [0x25"] {
            let found = try XCTUnwrap(text.range(of: rule), rule)
            XCTAssertLessThan(building.lowerBound, found.lowerBound, rule)
            XCTAssertLessThan(found.lowerBound, finalize.lowerBound, rule)
        }
    }

    /// The stock rule for every value of a key would answer first: a pier would be a
    /// nameless man-made area, a picnic site a nameless tourist one.
    func testARuleForOneValueGoesAheadOfTheRuleForEveryValueOfItsKey() throws {
        let stock = """
            leisure=park [0x17 resolution 20]
            # building tag should be last
            amenity=* & area!=no & amenity!=grave_yard {add name='${amenity|subst:"_=> "}'} [0x23 resolution 24]
            building=* & building!=no [0x13 resolution 24]
            tourism=* & area!=no & waterway!=* {add name='${tourism|subst:"_=> "}'} [0x21 resolution 24]

            # man_made can be used on areas or lines
            man_made=* & area!=no {add name='${man_made|subst:"_=> "}'} [0x24 resolution 24]

            <finalize>

            """
        let text = try polygons(after: stock)
        func at(_ line: String) throws -> String.Index { try XCTUnwrap(text.range(of: line), line).lowerBound }
        XCTAssertLessThan(try at("tourism=picnic_site [0x17"), try at("tourism=* & area!=no"))
        XCTAssertLessThan(try at("man_made=pier [0x25"), try at("# man_made can be used"))
        XCTAssertLessThan(try at("man_made=breakwater [0x25"), try at("man_made=* & area!=no"))
        // The stock rules above keep their place ahead of them, and no amenity ground
        // is taken for a building.
        XCTAssertLessThan(try at("leisure=park [0x17"), try at("man_made=pier [0x25"))
        XCTAssertLessThan(try at("building=* & building!=no"), try at("tourism=picnic_site [0x17"))
        XCTAssertFalse(text.contains("amenity=place_of_worship"))
        XCTAssertEqual(try polygons(after: text), text)
    }

    /// Adding them twice would put two rules in the file for every meaning here.
    func testAStyleThatAlreadyHasThemIsLeftAlone() throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("found-\(UUID().uuidString.prefix(6))")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try "waterway=stream | waterway=drain [0x18 resolution 22]\nwaterway=* [0x26 resolution 24]\n"
            .write(
                to: folder.appendingPathComponent("lines"),
                atomically: true,
                encoding: .utf8
            )

        let catalog = StyleCatalog(settings: SettingsStore(), toolchain: Toolchain(settings: SettingsStore()))
        try catalog.addFoundLineRules(in: folder, log: Log())
        let once = try String(contentsOf: folder.appendingPathComponent("lines"), encoding: .utf8)
        try catalog.addFoundLineRules(in: folder, log: Log())
        let twice = try String(contentsOf: folder.appendingPathComponent("lines"), encoding: .utf8)
        XCTAssertEqual(once, twice)
        XCTAssertEqual(twice.components(separatedBy: "waterway=ditch [0x18").count - 1, 1)
        // Ahead of the rule for every waterway, which draws a stream that runs dry.
        let ditch = try XCTUnwrap(twice.range(of: "waterway=ditch [0x18"))
        let every = try XCTUnwrap(twice.range(of: "waterway=* [0x26"))
        XCTAssertLessThan(ditch.lowerBound, every.lowerBound)
        // The one that runs dry is asked first, and keeps the dashed line.
        let dry = try XCTUnwrap(twice.range(of: "waterway=ditch & intermittent=yes [0x26"))
        XCTAssertLessThan(dry.lowerBound, ditch.lowerBound)
    }
}
