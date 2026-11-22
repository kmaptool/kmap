import XCTest

@testable import kmap

final class SubstitutionApplyTests: XCTestCase {
    // MARK: applySubstitutions

    /// A rule whose type is on its own line is not the rule the sheet names, whatever
    /// the line below it carries: that line is another rule's.
    func testARuleIsNeverRetypedOnTheLineOfTheRuleBelowIt() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("kmap-apply-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let rules = "a=b {name 'x'} [0x10 resolution 24]\nc=d [0x11 resolution 24]\n"
        try FileTools.write(rules, to: dir.appendingPathComponent("points"))
        let sheet = "@@ points\n- a=b [0x11 resolution 24]\n+ a=b [0x12 resolution 24]\n"
        let result = try StyleCatalog.applySubstitutions(sheet, in: dir)
        XCTAssertEqual(result.applied, 0)
        XCTAssertEqual(result.missed.count, 1)
        XCTAssertEqual(try String(contentsOf: dir.appendingPathComponent("points"), encoding: .utf8), rules)
    }

    /// The type of a rule written over 2 lines is found on the second.
    func testARuleWrittenOverTwoLinesIsRetypedOnItsSecond() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("kmap-apply-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileTools.write("a=b {name 'x'}\n    [0x11 resolution 24]\n", to: dir.appendingPathComponent("points"))
        let sheet = "@@ points\n- a=b [0x11 resolution 24]\n+ a=b [0x12 resolution 24]\n"
        XCTAssertEqual(try StyleCatalog.applySubstitutions(sheet, in: dir).applied, 1)
        XCTAssertEqual(
            try String(contentsOf: dir.appendingPathComponent("points"), encoding: .utf8),
            "a=b {name 'x'}\n    [0x12 resolution 24]\n"
        )
    }

    // MARK: ruleToken

    func testTheTypeTokenIsTheNumberWithoutTheRest() {
        XCTAssertEqual(StyleCatalog.ruleToken(of: "highway=path [0x16 road_class=0 resolution 23]"), "[0x16")
        XCTAssertEqual(StyleCatalog.ruleToken(of: "natural=wood [0x50]"), "[0x50")
        XCTAssertNil(StyleCatalog.ruleToken(of: "highway=path {set highway=footway}"))
    }

    // MARK: bareCondition

    func testTheConditionStopsAtTheActionsOrTheType() {
        XCTAssertEqual(StyleCatalog.bareCondition(of: "highway=steps {add bicycle=no} [0x0f]"), "highway=steps")
        XCTAssertEqual(StyleCatalog.bareCondition(of: "  waterway=canal [0x1f resolution 21]"), "waterway=canal")
        XCTAssertEqual(
            StyleCatalog.bareCondition(of: "a=b & c=d\n[0x01 resolution 24]"),
            "a=b & c=d",
            "only the first line of a 2-line rule"
        )
        XCTAssertNil(StyleCatalog.bareCondition(of: "[0x01 resolution 24]"))
    }

    // MARK: fittedStroke

    /// The rule below sets the name in this build's language.
    func testAStrokeLosesItsNameAndKeepsItsOtherActions() {
        let fitted = StyleCatalog.fittedStroke(
            "waterway=river {name '${name}'; set kmap:x=1} [0x26 resolution 22]",
            resolution: nil
        )
        XCTAssertEqual(fitted, "waterway=river {set kmap:x=1} [0x26 resolution 22]")
    }

    func testAStrokeWithOnlyANameLosesItsBlock() {
        XCTAssertEqual(
            StyleCatalog.fittedStroke("waterway=river {name '${name}'} [0x26 resolution 22]", resolution: nil),
            "waterway=river [0x26 resolution 22]"
        )
    }

    func testAStrokeFollowsTheRulesResolutionUnlessItHasABand() {
        XCTAssertEqual(
            StyleCatalog.fittedStroke("waterway=river [0x26 resolution 22]", resolution: "resolution 20"),
            "waterway=river [0x26 resolution 20]"
        )
        XCTAssertEqual(
            StyleCatalog.fittedStroke("waterway=river [0x26 resolution 18-21]", resolution: "resolution 20"),
            "waterway=river [0x26 resolution 18-21]"
        )
    }

    // MARK: pinToBand

    func testARuleTakesTheBandTheSheetPinnedItTo() {
        var line = "waterway=river [0x1f resolution 20]"
        StyleCatalog.pinToBand(&line, as: "waterway=river [0x1f resolution 18-22]", resolution: "resolution 20")
        XCTAssertEqual(line, "waterway=river [0x1f resolution 20-22]", "never coarser than this build draws it")
    }

    func testABandTheRuleCannotReachIsLeftOff() {
        var line = "waterway=river [0x1f resolution 23]"
        StyleCatalog.pinToBand(&line, as: "waterway=river [0x1f resolution 18-22]", resolution: "resolution 23")
        XCTAssertEqual(line, "waterway=river [0x1f resolution 23]")
    }

    func testARuleWithABandOfItsOwnOrASheetWithoutOneIsLeftAlone() {
        var banded = "waterway=river [0x1f resolution 19-21]"
        StyleCatalog.pinToBand(&banded, as: "waterway=river [0x1f resolution 18-22]", resolution: "resolution 19-21")
        XCTAssertEqual(banded, "waterway=river [0x1f resolution 19-21]")
        var plain = "waterway=river [0x1f resolution 20]"
        StyleCatalog.pinToBand(&plain, as: "waterway=river [0x1f resolution 22]", resolution: "resolution 20")
        XCTAssertEqual(plain, "waterway=river [0x1f resolution 20]")
    }
}
