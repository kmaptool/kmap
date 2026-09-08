import XCTest
@testable import kmap

/// Whether moving a family of features lands where it was asked to.
///
/// `resolution` is a threshold in bits, not a rung, and the ladders skip numbers: on
/// `0:24, 1:23, 2:22, 3:21, 4:19, …` there is no rung at 20, so a rule at 21 moved by one
/// bit lands on 20, which mkgmap draws from 21.
final class ZoomPlanTests: XCTestCase {

    private let smooth = ZoomRungs(levels: LevelsProfile.smooth.levels)

    func testARuleLandsOnTheFinestRungThatCanHoldIt() {
        XCTAssertEqual(smooth.bits, [24, 23, 22, 21, 19, 18, 17])
        XCTAssertEqual(smooth.rung(forResolution: 24), 0)
        XCTAssertEqual(smooth.rung(forResolution: 22), 2)
        // No rung at 20: mkgmap draws it from 21, so that is the rung it is on.
        XCTAssertEqual(smooth.rung(forResolution: 20), 3)
    }

    func testAMoveCountsRungsAndNotBits() {
        // 21 one step coarser is 19, not 20 -- there is no 20.
        XCTAssertEqual(smooth.moved(21, by: 1), 19)
        XCTAssertEqual(smooth.moved(24, by: 2), 22)
        // And back the other way.
        XCTAssertEqual(smooth.moved(19, by: -1), 21)
    }

    func testAMoveOffTheEndStopsAtTheEnd() {
        XCTAssertEqual(smooth.moved(18, by: 3), 17)
        XCTAssertEqual(smooth.moved(23, by: -3), 24)
        // Already at the end: nothing to report.
        XCTAssertNil(smooth.moved(17, by: 2))
        XCTAssertNil(smooth.moved(24, by: -1))
        XCTAssertNil(smooth.moved(22, by: 0))
    }

    func testTheStandardLadderMovesByItsOwnRungs() {
        let standard = ZoomRungs(levels: LevelsProfile.standard.levels)
        XCTAssertEqual(standard.bits, [24, 22, 20, 18])
        // One rung on this ladder is two bits, not one.
        XCTAssertEqual(standard.moved(24, by: 1), 22)
        XCTAssertEqual(standard.moved(22, by: 1), 20)
    }

    // MARK: Which rules a family claims

    private func family(_ id: String) -> ZoomFamily { ZoomFamily.named(id)! }

    func testAFamilyClaimsItsOwnTagsAndNothingNearThem() {
        let woodland = family("woodland")
        XCTAssertTrue(woodland.claims("landuse=forest | landuse=wood ", in: "polygons"))
        XCTAssertTrue(woodland.claims("natural=scrub ", in: "polygons"))
        // Not a longer word that merely starts the same way.
        XCTAssertFalse(woodland.claims("landuse=forestry ", in: "polygons"))
        XCTAssertFalse(woodland.claims("natural=wood_stack ", in: "polygons"))
        XCTAssertFalse(woodland.claims("highway=path ", in: "polygons"))
    }

    func testAKeyPatternClaimsAnyValue() {
        let railways = family("railways")
        XCTAssertTrue(railways.claims("railway=rail ", in: "lines"))
        XCTAssertTrue(railways.claims("aerialway=chair_lift & name!=* ", in: "lines"))
        XCTAssertFalse(railways.claims("highway=service & service=siding ", in: "lines"))
    }

    func testTheContoursClaimOnlyTheirOwnFile() {
        let contours = family("contours")
        // Every typed rule in its file, condition unread -- the file holds nothing else.
        XCTAssertTrue(contours.claims("", in: "inc/contour_lines"))
        // And nothing anywhere else, however it is worded.
        XCTAssertFalse(contours.claims("landuse=forest ", in: "polygons"))
        XCTAssertFalse(contours.claims("highway=path ", in: "lines"))
    }

    func testTheNarrowFamilyWinsATie() {
        // A track is a trail before it is a road, because trails come first in the list.
        let claimed = ZoomFamily.all.first { $0.claims("highway=track ", in: "lines") }
        XCTAssertEqual(claimed?.id, "trails")
        // And a forest is woodland before it is other land use.
        XCTAssertEqual(ZoomFamily.all.first { $0.claims("landuse=forest ", in: "polygons") }?.id, "woodland")
    }

    // MARK: The plan itself

    func testTheBuiltInPlansSayNothing() {
        for plan in ZoomPlan.builtins {
            XCTAssertFalse(plan.movesAnything, "\(plan.name) should be the style as it comes")
            XCTAssertTrue(plan.isBuiltin)
        }
    }

    func testAWindowIsARunWhicheverWayItIsGiven() {
        // Coarse-first or fine-first is the same run of rungs; the editor builds one end
        // at a time.
        XCTAssertEqual(ZoomPlan.Window(finest: 1, coarsest: 4).rungs, 1...4)
        XCTAssertEqual(ZoomPlan.Window(finest: 4, coarsest: 1).rungs, 1...4)
        XCTAssertEqual(ZoomPlan.Window(finest: 2, coarsest: 2).count, 1)
        XCTAssertTrue(ZoomPlan.Window(finest: 1, coarsest: 4).contains(3))
        XCTAssertFalse(ZoomPlan.Window(finest: 1, coarsest: 4).contains(5))
    }

    func testAFamilyBackAtItsOwnRungsLeavesNoTrace() {
        var plan = ZoomPlan(id: "mine", name: "Mine", levelsID: LevelsProfile.smooth.id)
        plan.setWindow(.init(finest: 0, coarsest: 2), for: family("trails"))
        XCTAssertEqual(plan.window(family("trails"))?.rungs, 0...2)
        XCTAssertTrue(plan.movesAnything)
        plan.setWindow(nil, for: family("trails"))
        XCTAssertTrue(plan.windows.isEmpty, "an untouched family should leave no trace")
        XCTAssertFalse(plan.movesAnything)
    }
}
