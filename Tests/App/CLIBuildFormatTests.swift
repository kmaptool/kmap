import XCTest

@testable import kmap

/// `--format` on `kmap build`: the profile's word unless the flag says otherwise, and a
/// word nothing answers to is refused rather than swapped for the default.
final class CLIBuildFormatTests: XCTestCase {
    private func resolve(_ arguments: [String], profile: String = "img") -> (OutputFormat, [String]) {
        var asked = CLI.BuildOptions(CLI.Flags(arguments))
        var choices = BuildChoices()
        choices.format = profile
        let format = CLI.outputFormat(&asked, choices: choices)
        return (format, asked.refused)
    }

    func testTheProfileDecidesWhenTheFlagIsAbsent() {
        XCTAssertEqual(resolve([]).0, .img)
        XCTAssertEqual(resolve([], profile: "gmap").0, .gmap)
        XCTAssertEqual(resolve([], profile: "folder").0, .img, "an unreadable stored word writes card files")
    }

    func testTheFlagOverridesTheProfile() {
        let (format, refused) = resolve(["--format=both"], profile: "gmap")
        XCTAssertEqual(format, .both)
        XCTAssertTrue(refused.isEmpty)
        XCTAssertEqual(resolve(["--format=GMAP"]).0, .gmap, "matched without regard to case")
    }

    func testAnUnknownWordIsRefusedAndNamesTheChoices() {
        let (_, refused) = resolve(["--format=xml"])
        XCTAssertEqual(refused.count, 1)
        XCTAssertTrue(refused[0].contains("img, gmap, both"), refused[0])
    }
}
