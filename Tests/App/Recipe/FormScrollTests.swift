import XCTest

@testable import kmap

/// A form taller than the terminal scrolls to the selected row rather than drawing the
/// rows past the bottom nowhere.
@MainActor
final class FormScrollTests: XCTestCase {
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

    private func screen(_ form: RecipeForm, height: Int) -> String {
        let surface = Surface()
        surface.resize(80, height)
        surface.clear(ctx.theme.base)
        form.render(into: surface, rect: Rect(x: 2, y: 2, w: 76, h: height - 4), ctx: ctx)
        return stripControlSequences(surface.compose())
    }

    func testTheSaveButtonIsDrawnOnAShortTerminalWhenSelected() async {
        let form = form()
        XCTAssertFalse(screen(form, height: 24).contains(t("Save profile")), "the form is taller than 20 rows")
        form.list.selected = form.fields.count - 1
        XCTAssertTrue(screen(form, height: 24).contains(t("Save profile")))
        XCTAssertNotNil(form.fieldRows[.save])
        // And back to the top: the first field returns, the button goes.
        form.list.selected = 0
        let top = screen(form, height: 24)
        XCTAssertTrue(top.contains(form.fields[0].label))
        XCTAssertFalse(top.contains(t("Save profile")))
    }

    func testATallTerminalDrawsTheWholeFormWithoutScrolling() async {
        let form = form()
        form.list.selected = form.fields.count - 1
        let whole = screen(form, height: 44)
        XCTAssertTrue(whole.contains(t("Save profile")))
        XCTAssertTrue(whole.contains(form.fields[0].label))
        XCTAssertEqual(form.scroll, 0)
    }
}
