import XCTest

@testable import kmap

/// `--format` on `kmap build`: the profile's word unless the flag says otherwise, and a
/// word nothing answers to is refused rather than swapped for the default.
final class CLIBuildRequestTests: XCTestCase {
    private func resolve(_ arguments: [String], profile: String = "img") -> (OutputFormat, [String]) {
        var asked = CLI.BuildOptions(CLI.Flags(arguments))
        var choices = BuildChoices()
        choices.format = profile
        let format = CLI.BuildRequest.outputFormat(&asked, choices: choices)
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

    private func request(_ arguments: [String], choices: BuildChoices = BuildChoices()) -> (CLI.BuildRequest?, [String])
    {
        var asked = CLI.BuildOptions(CLI.Flags(arguments, valued: CLI.buildValuedOptions))
        let store = SettingsStore()
        let catalog = StyleCatalog(settings: store, toolchain: Toolchain(settings: store))
        let request = CLI.BuildRequest(&asked, choices: choices, store: store, catalog: catalog)
        return (request, asked.refused)
    }

    /// Every wrong flag is said at once, so the command line is fixed in 1 go.
    func testEveryWrongFlagIsRefusedTogether() {
        let (request, refused) = request(["austria", "--sources=nowhere", "--heap=9999"])
        XCTAssertNil(request)
        XCTAssertEqual(refused.count, 2, "\(refused)")
    }

    /// The flags given win over the profile; the rest is the profile's.
    func testTheRecipeTakesTheFlagsOverTheProfile() throws {
        var choices = BuildChoices()
        choices.contours = true
        let (made, refused) = request(["austria", "--no-contours", "--interval=50"], choices: choices)
        let request = try XCTUnwrap(made, "\(refused)")
        let region = Region(
            id: "austria",
            name: "Austria",
            parentID: nil,
            pbfURL: nil,
            bbox: BBox(minLon: 9, minLat: 46, maxLon: 17, maxLat: 49),
            boxes: []
        )
        let recipe = request.recipe(for: [region], in: RegionIndex())
        XCTAssertFalse(recipe.contours)
        XCTAssertEqual(recipe.contourInterval, 50)
        XCTAssertEqual(recipe.routable, choices.routable)
    }
}
