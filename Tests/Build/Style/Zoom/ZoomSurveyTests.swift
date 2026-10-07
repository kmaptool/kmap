import XCTest

@testable import kmap

/// Where each family of features starts and stops, read from a style's own rules.
final class ZoomSurveyTests: XCTestCase {
    private var directory = URL(fileURLWithPath: "/tmp")

    override func setUpWithError() throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("kmap-survey-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    /// A family and two rules of its own, at the finest rung and one further out.
    private func surveyed() throws -> (ZoomSurvey, ZoomFamily, far: Int) {
        let rungs = ZoomRungs(levels: LevelsProfile.smooth.levels)
        let family = try XCTUnwrap(
            ZoomFamily.all.first { $0.claims("highway=path", in: "lines") },
            "no family claims a path"
        )
        let far = rungs.bits[2]
        try FileTools.write(
            """
            highway=path [0x16 resolution \(rungs.bits[0])]
            highway=path & bicycle=yes [0x16 resolution \(far)]
            """,
            to: directory.appendingPathComponent("lines")
        )
        return (ZoomSurvey(styleAt: directory, levels: .smooth), family, far)
    }

    func testAStyleWithoutRulesSurveysAsEmpty() {
        let survey = ZoomSurvey(styleAt: directory, levels: .smooth)
        XCTAssertTrue(survey.isEmpty)
        XCTAssertNil(survey.shift(putting: ZoomFamily.all[0], onRung: 1))
    }

    func testAFamilySpreadsFromItsFinestRuleToItsCoarsest() throws {
        let (survey, family, _) = try surveyed()
        XCTAssertFalse(survey.isEmpty)
        let spread = try XCTUnwrap(survey.spread(family))
        XCTAssertEqual(spread.finest, 0)
        XCTAssertEqual(spread.coarsest, 2)
        XCTAssertEqual(spread.rules, 2)
    }

    func testAMoveIsCountedFromWhereTheFamilyStartsNow() throws {
        let (survey, family, _) = try surveyed()
        XCTAssertEqual(survey.shift(putting: family, onRung: 4), 2, "two rungs coarser")
        XCTAssertEqual(survey.shift(putting: family, onRung: 2), 0)
        XCTAssertEqual(survey.shift(putting: family, onRung: 0), -2)
    }

    func testARungReadsAsItsNumberAndNeverPastTheLadder() throws {
        let (survey, _, _) = try surveyed()
        let last = survey.rungs.bits.count - 1
        XCTAssertTrue(survey.rungLabel(1).contains("1"))
        XCTAssertEqual(survey.rungLabel(99), survey.rungLabel(last), "clamped to the last rung")
        XCTAssertEqual(survey.rungLabel(-5), survey.rungLabel(0))
        XCTAssertTrue(survey.startsAt(rung: 2).contains("2"))
        XCTAssertTrue(survey.stopsAt(rung: 3).contains("3"))
        XCTAssertNotEqual(survey.startsAt(rung: 2), survey.stopsAt(rung: 2), "two sentences, not one")
    }

    /// Every rung of every ladder kmap offers says roughly how far it is from the eye,
    /// short enough for a column of the zoom grid: never a bare rung number beside the
    /// scales, which read as one more distance.
    func testEveryRungOfEveryLadderHasARoughScaleThatFitsItsColumn() {
        for profile in LevelsProfile.all {
            for bits in ZoomRungs(levels: profile.levels).bits {
                let short = ZoomRungs.shortScale(bits: bits)
                XCTAssertNotNil(short, "\(profile.id) rung \(bits)")
                XCTAssertTrue(short?.hasPrefix("≈") ?? false, "\(profile.id) rung \(bits) reads as exact")
                XCTAssertLessThanOrEqual(short?.count ?? 0, 6, "\(profile.id) rung \(bits)")
            }
        }
    }
}
