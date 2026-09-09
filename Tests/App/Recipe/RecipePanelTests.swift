import XCTest
@testable import kmap

/// The panel beside the new-map form carries what the form itself does not: what the
/// build will cost, where it lands, what will bite, and what the row under the cursor
/// is for.
final class RecipePanelTests: XCTestCase {

    private var ctx: AppContext!

    @MainActor
    override func setUp() async throws {
        ctx = AppContext()
    }

    private static let somewhere = Region(
        id: "large-region", name: "Large Inland Region",
        parentID: nil, pbfURL: nil,
        bbox: BBox(minLon: 32.15, minLat: 43.18, maxLon: 36.68, maxLat: 46.25),
        boxes: [], childIDs: [])

    @MainActor
    private func drawn(_ screen: RecipeScreen) -> String {
        let surface = Surface()
        surface.resize(120, 44)
        surface.clear(ctx.theme.base)
        screen.tick(ctx)
        screen.render(into: surface, rect: Rect(x: 2, y: 2, w: 116, h: 40), ctx: ctx)
        return surface.asText()
    }

    @MainActor
    private func screen() -> RecipeScreen {
        RecipeScreen(region: Self.somewhere, settings: ctx.settings, hasSeamPatch: true)
    }

    @MainActor
    func testThePanelSaysWhatTheFormCannot() async {
        let text = drawn(screen())
        for wanted in ["REGION", "COST", "OUTPUT FOLDER"] {
            XCTAssertTrue(text.contains(wanted), "the panel should still say \(wanted)")
        }
        XCTAssertTrue(text.contains("Large Inland Region"))
    }

    /// The explanation on the panel belongs to the row under the cursor, and goes away
    /// when the cursor leaves it.
    @MainActor
    func testTheExplanationFollowsTheCursor() async {
        let screen = self.screen()
        _ = drawn(screen)                       // rows exist only after a render

        // Walk to the road-repair row and read its explanation.
        var found = false
        for _ in 0..<40 {
            if drawn(screen).contains("that is a dead end") { found = true; break }
            _ = screen.handle(.down, ctx: ctx)
        }
        XCTAssertTrue(found, "the road-repair row should explain itself")

        // And it goes away again when the cursor does.
        _ = screen.handle(.up, ctx: ctx)
        XCTAssertFalse(drawn(screen).contains("that is a dead end"),
                       "an explanation for a row nobody is on is a screen nobody reads")
    }

    /// A warning is only worth a line when it is true of this map.
    @MainActor
    func testAWarningAppearsOnlyWhenItApplies() async {
        let screen = self.screen()
        let text = drawn(screen)
        // The default code page cannot hold Cyrillic, and the fixture's ground lies east
        // of the meridian the warning is drawn from.
        XCTAssertTrue(text.contains("1252"), "a western code page over Cyrillic ground is worth saying")
        XCTAssertTrue(text.contains("WORTH KNOWING"))
    }
}
