import XCTest
@testable import kmap

/// The choice types: the split mode and the level ladder.
final class BuildChoicesTypesTests: RecipeTestCase {

    // MARK: How the map is cut into files

    func testTheSplitModeSurvivesBeingStoredAsAWordAndANumber() {
        for mode in [SplitMode.fitCard, .perRegion, .perCountry, .count(3)] {
            let restored = SplitMode(settingsID: mode.settingsID, count: mode.fileCount)
            XCTAssertEqual(restored, mode, mode.settingsID)
        }
    }

    func testAnUnknownStoredModeFallsBackToTheAutomaticOne() {
        // A settings file from a future version, or a hand-edited one.
        XCTAssertEqual(SplitMode(settingsID: "whatever", count: 0), .fitCard)
        XCTAssertEqual(SplitMode(settingsID: "", count: 0), .fitCard)
        // "custom" with a nonsense count still has to make at least one file.
        XCTAssertEqual(SplitMode(settingsID: "custom", count: 0), .count(1))
        XCTAssertEqual(SplitMode(settingsID: "custom", count: -5), .count(1))
    }

    func testOnlyTheCountedModeCarriesANumber() {
        XCTAssertEqual(SplitMode.fitCard.fileCount, 0)
        XCTAssertEqual(SplitMode.perRegion.fileCount, 0)
        XCTAssertEqual(SplitMode.count(4).fileCount, 4)
        XCTAssertEqual(SplitMode.count(1).label, "1 file")
        XCTAssertEqual(SplitMode.count(4).label, "4 files")
    }

    // MARK: The DEM ladder

    func testTheDEMLadderIsTheMeasuredConstant() {
        // A fixed ladder, validated against hardware.
        let one = LevelsProfile.smooth.demDists(oneArcSecond: true)
        XCTAssertEqual(one, "3312,5568,9360,15760,26496,52992,106048")
        let three = LevelsProfile.smooth.demDists(oneArcSecond: false)
        XCTAssertEqual(three, "9936,12704,16224,20736,26496,52992,106048")
    }

    /// Every ladder is increasing, free of duplicates, no longer than the profile's level
    /// count, and keeps its coarse end whole.
    func testEveryProfileKeepsTheMeasuredCoarseEnd() {
        for profile in LevelsProfile.all {
            for oneArcSecond in [true, false] {
                let where_ = "\(profile.id), \(oneArcSecond ? "1\"" : "3\"")"
                let dists = profile.demDists(oneArcSecond: oneArcSecond)
                    .split(separator: ",").compactMap { Int($0) }
                XCTAssertEqual(dists, dists.sorted(), "\(where_): mkgmap needs them increasing")
                XCTAssertEqual(Set(dists).count, dists.count, "\(where_): a repeated rung is a wasted level")
                XCTAssertLessThanOrEqual(dists.count, profile.levelCount, "\(where_): more rungs than levels")
                XCTAssertTrue(dists.allSatisfy { $0 % 16 == 0 }, "\(where_): mkgmap rounds to 16s")
                XCTAssertEqual(Array(dists.suffix(3)), [26496, 52992, 106048],
                               "\(where_): the measured coarse end must survive whole")
            }
        }
    }
}
