import XCTest
@testable import kmap

/// Every kmap rule pass, run in the build's own order over a stand-in for the stock
/// style. The real one comes out of mkgmap and is not in the repository, so the stand-in
/// holds only what the passes look for: the rule files, a `<finalize>` section and the
/// stock lines three of the passes anchor on.
final class RulePassesTests: XCTestCase {

    private var directory = URL(fileURLWithPath: "/tmp")
    private let ruleFiles = ["points", "lines", "polygons", "relations"]
    private let woodland = "landuse=forest | landuse=wood [0x50"

    /// The stock lines the anchored passes aim at, as mkgmap's default style spells them.
    private let anchors = [
        "points": ["amenity=drinking_water [0x5000 resolution 24]",
                   "natural=spring [0x6511 resolution 24]"],
        "polygons": ["landuse=forest | landuse=wood [0x50 resolution 20]"],
    ]

    override func setUpWithError() throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("kmap-rules-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func catalog() -> StyleCatalog {
        let settings = SettingsStore()
        return StyleCatalog(settings: settings, toolchain: Toolchain(settings: settings))
    }

    /// As the stock style has it: every rule file ends in a `<finalize>` section of
    /// actions, except `relations`, which has none.
    private func writeStandIn(withAnchors: Bool = true) throws {
        for name in ruleFiles {
            var lines = ["# stand-in for the stock \(name) file", "stock:first=yes [0x01 resolution 24]"]
            if withAnchors { lines += anchors[name] ?? [] }
            lines += ["stock:last=yes [0x02 resolution 24]", ""]
            if name != "relations" { lines += ["<finalize>", "name=* { name '${name}' }", ""] }
            try lines.joined(separator: "\n")
                .write(to: directory.appendingPathComponent(name), atomically: true, encoding: .utf8)
        }
    }

    private func read(_ name: String) throws -> String {
        try String(contentsOf: directory.appendingPathComponent(name), encoding: .utf8)
    }

    private func snapshot() throws -> [String: String] {
        try Dictionary(uniqueKeysWithValues: ruleFiles.map { ($0, try read($0)) })
    }

    /// kmap's block headers, `# --- kmap: ...`, as they stand in a file.
    private func markers(in text: String) -> [String] {
        text.split(separator: "\n").map(String.init)
            .filter { $0.trimmingCharacters(in: .whitespaces).hasPrefix("# --- kmap:") }
    }

    // MARK: The contract

    func testEveryStockLineSurvivesThePasses() throws {
        try writeStandIn()
        let before = try snapshot()
        try catalog().applyRulePasses(in: directory, cyrillicLabels: false, log: Log(showing: .error))
        for name in ruleFiles {
            let after = try read(name)
            for line in try XCTUnwrap(before[name]).split(separator: "\n") {
                // The one stock rule a pass rewrites on purpose: woodland is shown earlier,
                // so its resolution changes and the rest of the line stays.
                let kept = line.hasPrefix(woodland) ? Substring(woodland) : line
                XCTAssertTrue(after.contains(kept), "\(name) lost its stock line: \(line)")
            }
        }
    }

    func testThePassesWriteTheirBlocksIntoTheFilesTheyBelongTo() throws {
        try writeStandIn()
        try catalog().applyRulePasses(in: directory, cyrillicLabels: false, log: Log(showing: .error))
        for name in ["points", "lines", "polygons"] {
            XCTAssertGreaterThan(markers(in: try read(name)).count, 2, "\(name) got no kmap blocks")
        }
    }

    func testNoBlockIsWrittenTwice() throws {
        try writeStandIn()
        try catalog().applyRulePasses(in: directory, cyrillicLabels: false, log: Log(showing: .error))
        for name in ruleFiles {
            let found = markers(in: try read(name))
            XCTAssertEqual(found.count, Set(found).count, "\(name) carries a block twice")
        }
    }

    func testASecondRunChangesNothing() throws {
        // A style directory is amended once: the markers say what is already there.
        try writeStandIn()
        let styles = catalog()
        try styles.applyRulePasses(in: directory, cyrillicLabels: true, log: Log(showing: .error))
        let once = try snapshot()
        try styles.applyRulePasses(in: directory, cyrillicLabels: true, log: Log(showing: .error))
        XCTAssertEqual(try snapshot(), once)
    }

    func testNothingAfterFinalizeDefinesAType() throws {
        // A <finalize> section may hold only actions: mkgmap refuses a type definition
        // there. kmap does write into it, the address fallback, and only actions.
        try writeStandIn()
        try catalog().applyRulePasses(in: directory, cyrillicLabels: false, log: Log(showing: .error))
        for name in ruleFiles where name != "relations" {
            let lines = try read(name).components(separatedBy: "\n")
            let at = try XCTUnwrap(lines.firstIndex(of: "<finalize>"), "\(name) lost its <finalize>")
            XCTAssertEqual(lines.filter { $0 == "<finalize>" }.count, 1, name)
            for line in lines[(at + 1)...] where !line.hasPrefix("#") {
                XCTAssertFalse(line.contains("[0x"), "\(name) defines a type after <finalize>: \(line)")
            }
            XCTAssertGreaterThan(markers(in: lines[..<at].joined(separator: "\n")).count, 1,
                                 "\(name): the typed blocks belong ahead of <finalize>")
        }
    }

    // MARK: Anchors

    func testAnAnchoredBlockLandsImmediatelyAheadOfItsStockRule() throws {
        // First match wins, so these blocks are worth nothing below the rule they refine.
        try writeStandIn()
        try catalog().applyRulePasses(in: directory, cyrillicLabels: false, log: Log(showing: .error))
        for (name, stockLines) in anchors {
            let text = try read(name)
            for stock in stockLines {
                let sought = stock.hasPrefix(woodland) ? woodland : stock
                let at = try XCTUnwrap(text.range(of: sought), sought).lowerBound
                XCTAssertFalse(markers(in: String(text[..<at])).isEmpty,
                               "nothing was put ahead of \(stock)")
            }
        }
    }

    func testAStockRuleThatHasMovedIsReportedRatherThanGuessedAt() throws {
        try writeStandIn(withAnchors: false)
        let log = Log(showing: .debug)
        try catalog().applyRulePasses(in: directory, cyrillicLabels: false, log: log)
        let warnings = log.snapshot().filter { $0.severity == .warn }
        XCTAssertGreaterThanOrEqual(warnings.count, 3, "one per anchored pass that found nothing")
    }

    func testAStyleWithoutRuleFilesIsLeftAlone() throws {
        try catalog().applyRulePasses(in: directory, cyrillicLabels: false, log: Log(showing: .error))
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty)
    }

    // MARK: The two alphabets

    func testBothAlphabetsCarryTheSameBlocksInDifferentWords() throws {
        try writeStandIn()
        try catalog().applyRulePasses(in: directory, cyrillicLabels: false, log: Log(showing: .error))
        let latin = try snapshot()
        try writeStandIn()
        try catalog().applyRulePasses(in: directory, cyrillicLabels: true, log: Log(showing: .error))
        let cyrillic = try snapshot()

        XCTAssertNotEqual(latin["points"], cyrillic["points"], "the labels should differ")
        for name in ruleFiles {
            XCTAssertEqual(markers(in: try XCTUnwrap(latin[name])),
                           markers(in: try XCTUnwrap(cyrillic[name])), name)
        }
        let hasCyrillic: (String) -> Bool = { $0.unicodeScalars.contains { (0x400...0x4FF).contains($0.value) } }
        XCTAssertTrue(hasCyrillic(try XCTUnwrap(cyrillic["points"])))
    }

    // MARK: Descriptions

    func testEveryCarrierPutsTheDescriptionSomewhereAndOffPutsItNowhere() throws {
        var seen: Set<String> = []
        for carrier in BuildRecipe.DescriptionCarrier.allCases {
            try writeStandIn()
            let stock = try read("points")
            try catalog().addDescriptionRules(in: directory, carrier: carrier, log: Log(showing: .error))
            let text = try read("points")
            if carrier == .off {
                XCTAssertEqual(text, stock, "off writes nothing")
            } else {
                XCTAssertEqual(markers(in: text).count, 1, "\(carrier)")
                XCTAssertTrue(text.contains("description"), "\(carrier)")
                XCTAssertTrue(seen.insert(text).inserted, "\(carrier) writes the same rules as another")
            }
        }
    }

    func testDescriptionsAreWrittenOnce() throws {
        try writeStandIn()
        let styles = catalog()
        try styles.addDescriptionRules(in: directory, carrier: .street, log: Log(showing: .error))
        let once = try read("points")
        try styles.addDescriptionRules(in: directory, carrier: .street, log: Log(showing: .error))
        XCTAssertEqual(try read("points"), once)
    }
}
