import XCTest

@testable import kmap

final class SubstitutionApplyTests: XCTestCase {
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
