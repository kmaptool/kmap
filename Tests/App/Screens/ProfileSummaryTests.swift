import XCTest

@testable import kmap

/// The lines the profiles screen sums a profile up in.
@MainActor
final class ProfileSummaryTests: XCTestCase {
    func testCardFilesAreSummedUpByHowTheyAreCut() async {
        let lines = ProfilesScreen.summary(of: BuildChoices())
        XCTAssertTrue(lines.contains(SplitMode.fitCard.label))
        XCTAssertFalse(lines.contains(OutputFormat.img.label), "the default format goes unsaid")
    }

    func testAFolderIsNamedInsteadOfACut() async {
        var choices = BuildChoices()
        choices.format = OutputFormat.gmap.rawValue
        let lines = ProfilesScreen.summary(of: choices)
        XCTAssertTrue(lines.contains(OutputFormat.gmap.label))
        XCTAssertFalse(lines.contains(SplitMode.fitCard.label), "a folder is never cut")

        choices.format = OutputFormat.both.rawValue
        let both = ProfilesScreen.summary(of: choices)
        XCTAssertTrue(both.contains(SplitMode.fitCard.label))
        XCTAssertTrue(both.contains(OutputFormat.both.label))
    }
}
