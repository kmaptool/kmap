import XCTest
@testable import kmap

/// The profile row at the top of the build form: choosing a profile fills the form in and
/// is remembered, while a change made on the form is not written back to the profile.
/// `@MainActor` because the screens are, and every test is `async` because Linux's
/// generated test list cannot name a synchronous main-actor method.
@MainActor
final class RecipeProfileTests: XCTestCase {

    private var ctx: AppContext!

    override func setUp() {
        // On Linux `setUp` is nonisolated, so the isolation has to be stated to reach
        // this class's own properties.
        MainActor.assumeIsolated {
            super.setUp()
            ctx = AppContext()
            let settings = ctx.settings
            let profiles = settings.settings.profiles
            let last = settings.settings.lastProfileID
            addTeardownBlock { @MainActor in
                settings.update { $0.profiles = profiles; $0.lastProfileID = last }
            }

            // Two profiles that differ in something the form draws in plain sight.
            var coarse = BuildChoices()
            coarse.contourInterval = 50
            var fine = BuildChoices()
            fine.contourInterval = 5
            settings.update {
                $0.profiles = [BuildProfile(id: "coarse", name: "Coarse", choices: coarse),
                               BuildProfile(id: "fine", name: "Fine", choices: fine)]
                $0.lastProfileID = "coarse"
            }
        }
    }

    /// No downloadable extract, so nothing is probed and no network is touched.
    private var region: Region {
        Region(id: "continent/inland-region", name: "Inland Region", parentID: "continent",
               pbfURL: nil,
               bbox: BBox(minLon: 9, minLat: 46, maxLon: 17, maxLat: 49), boxes: [])
    }

    /// Built without the seam patch unless a test asks for it: the overlap rows are the
    /// only ones on the form that depend on the toolchain.
    private func screen(hasSeamPatch: Bool = false) -> RecipeScreen {
        RecipeScreen(region: region, settings: ctx.settings, hasSeamPatch: hasSeamPatch)
    }

    @discardableResult
    private func drawn(_ screen: Screen) -> String {
        let surface = Surface()
        surface.resize(140, 44)
        surface.clear(ctx.theme.base)
        screen.tick(ctx)
        let rect = Rect(x: 2, y: 2, w: 136, h: 40)
        screen.render(into: surface, rect: rect, ctx: ctx)
        // Both passes, the way the app draws: an open list is an overlay.
        screen.renderOverlay(into: surface, rect: rect, ctx: ctx)
        return surface.compose()
    }

    func testTheOverlapRowsFollowTheSeamPatch() async {
        XCTAssertFalse(drawn(screen()).contains("Land overlap"),
                       "a stock mkgmap cannot draw past a frame, so the row would be a"
                           + " promise the build cannot keep")
        let patched = drawn(screen(hasSeamPatch: true))
        XCTAssertTrue(patched.contains("Tile overlap"), "with the patch both rows are on offer")
        XCTAssertTrue(patched.contains("Land overlap"))
        // The tile overlap and the ground it covers are both named.
        XCTAssertTrue(patched.contains("2048"), "the tile overlap says its own figure")
        XCTAssertTrue(patched.contains("640"), "and the land its own")
    }

    /// The form carries the elevation download cost. The figure is measured against the
    /// remote store, so offline the screen says only that it is being worked out.
    func testThePanelSaysWhatTheElevationWillCost() async {
        let frame = drawn(screen())
        XCTAssertTrue(frame.lowercased().contains("elevation"),
                      "the block has to be there when a build takes elevation at all")
        XCTAssertTrue(frame.contains("costs to fetch") || frame.contains("to download")
                          || frame.contains("cell"),
                      "and say either the figure or that it is being worked out")
    }

    func testTheFormOpensOnTheProfileAndSaysWhichOne() async {
        let screen = self.screen()
        let frame = drawn(screen)
        XCTAssertTrue(frame.contains("Coarse"), "the profile in use has to be on the form")
        XCTAssertTrue(frame.contains("50 m"), "and the form has to be filled in from it")
    }

    func testChoosingAnotherProfileFillsTheFormInFromItAndIsRemembered() async {
        let screen = self.screen()
        drawn(screen)

        // The profile row is the first one, so the cursor is already on it.
        _ = screen.handle(.right, ctx: ctx)
        let frame = drawn(screen)
        XCTAssertTrue(frame.contains("Fine"))
        XCTAssertTrue(frame.contains("5 m"), "changing the profile changes the choices")
        XCTAssertFalse(frame.contains("50 m"))

        // Remembered in this instance and on disk.
        XCTAssertEqual(ctx.settings.currentProfile.id, "fine")
        XCTAssertEqual(SettingsStore().currentProfile.id, "fine")
    }

    func testAChangeOnTheFormIsSaidOutLoudAndNotWrittenDown() async {
        let screen = self.screen()
        drawn(screen)

        // Down to Contour lines, then Interval, and move it off what the profile says.
        _ = screen.handle(.down, ctx: ctx)
        _ = screen.handle(.down, ctx: ctx)
        _ = screen.handle(.down, ctx: ctx)
        _ = screen.handle(.right, ctx: ctx)

        let frame = drawn(screen)
        XCTAssertFalse(frame.contains("50 m"), "the interval should have moved")
        XCTAssertTrue(frame.contains("changed for this map only"),
                      "a form moved off its profile has to say so")

        // The profile itself is exactly as it was, before and after backing out.
        XCTAssertEqual(ctx.settings.profile("coarse")?.choices.contourInterval, 50)
        _ = screen.handle(.esc, ctx: ctx)
        XCTAssertEqual(ctx.settings.profile("coarse")?.choices.contourInterval, 50)

        // And the next map opens on the profile, not on what was left on the last screen.
        let again = self.screen()
        XCTAssertTrue(drawn(again).contains("50 m"))
    }

    func testTheProfileRowOpensTheListOfThemInTheOrderTheyAreOffered() async {
        let screen = self.screen()
        drawn(screen)
        _ = screen.handle(.enter, ctx: ctx)
        XCTAssertTrue(screen.footerHints.contains { $0.label == "take it" },
                      "⏎ on the profile row should open the list")
        let frame = drawn(screen)
        XCTAssertTrue(frame.contains("Coarse") && frame.contains("Fine"))
    }
}
