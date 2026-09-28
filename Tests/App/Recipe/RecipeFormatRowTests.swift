import XCTest

@testable import kmap

/// The Format row on the build form: what it offers, and what it switches off.
@MainActor
final class RecipeFormatRowTests: XCTestCase {
    private var ctx: AppContext!

    override func setUp() {
        MainActor.assumeIsolated {
            super.setUp()
            ctx = AppContext()
        }
    }

    private func form() -> RecipeForm {
        let region = Region(id: "", name: "", parentID: nil, pbfURL: nil, bbox: .empty, boxes: [])
        let style = MapStyle(
            id: "plain",
            name: "Plain",
            summary: "",
            origin: .builtin,
            styleDirectory: nil,
            typURL: nil,
            familyID: 6324,
            productID: 1
        )
        let recipe = BuildRecipe(region: region, style: style, outputDirectory: URL(fileURLWithPath: "/tmp"))
        return RecipeForm(mode: .profile, recipe: recipe)
    }

    func testTheRowOffersTheThreeFormatsAndOpensOnTheCard() async {
        let form = form()
        let choice = form.choice(for: .format, ctx)
        XCTAssertEqual(choice?.options, OutputFormat.allCases.map(\.label))
        XCTAssertEqual(choice?.current, 0, "a fresh recipe writes card files")
        XCTAssertTrue(form.fields.contains(.format), "offered in profile mode too")
        XCTAssertTrue(form.value(for: .format).hasPrefix(OutputFormat.img.label))
    }

    func testAFolderAloneSwitchesTheCuttingRowsOff() async {
        let form = form()
        _ = form.choice(for: .format, ctx)?.choose(1)
        XCTAssertEqual(form.recipe.format, .gmap)
        XCTAssertNil(form.choice(for: .splitMode, ctx), "a folder is never cut")
        XCTAssertNil(form.choice(for: .parts, ctx))
        XCTAssertEqual(form.value(for: .splitMode), "—")
        XCTAssertEqual(form.value(for: .parts), "—")

        _ = form.choice(for: .format, ctx)?.choose(2)
        XCTAssertEqual(form.recipe.format, .both)
        XCTAssertNotNil(form.choice(for: .splitMode, ctx), "card files are written again")
        XCTAssertEqual(form.value(for: .splitMode), SplitMode.fitCard.label)
    }

    func testTheChoiceTravelsIntoTheProfile() async {
        let form = form()
        _ = form.choice(for: .format, ctx)?.choose(2)
        XCTAssertEqual(form.recipe.choices.format, "both")
    }
}
