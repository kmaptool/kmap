import XCTest

@testable import kmap

/// The House numbers row: found only through address search, so with the index off it
/// shows nothing to choose, and the choice made earlier waits for the index to return.
@MainActor
final class RecipeHouseNumbersRowTests: XCTestCase {
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

    func testWithTheIndexOffTheRowHasNothingToChoose() async {
        let form = form()
        form.recipe.houseNumbers = true
        form.recipe.searchIndex = false
        XCTAssertNil(form.choice(for: .houseNumbers, ctx))
        XCTAssertEqual(form.value(for: .houseNumbers), "—")
        XCTAssertFalse(form.recipe.writesHouseNumbers)
    }

    func testTheIndexBackOnBringsTheEarlierChoiceBack() async {
        let form = form()
        form.recipe.houseNumbers = true
        form.recipe.searchIndex = false
        form.recipe.searchIndex = true
        XCTAssertNotNil(form.choice(for: .houseNumbers, ctx))
        XCTAssertEqual(form.value(for: .houseNumbers), t("on"))
        XCTAssertTrue(form.recipe.writesHouseNumbers)
    }
}
