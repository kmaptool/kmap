import XCTest
@testable import kmap

/// Whether the plan reaches the style a build compiles, through the path a build takes.
final class ZoomWiringTests: XCTestCase {

    /// The materialized style's identity changes with the plan; otherwise a second build
    /// finds the marker matching and reuses the rules from the first.
    @MainActor
    func testTheStyleIdentityChangesWithThePlan() async throws {
        let settings = SettingsStore()
        let catalog = StyleCatalog(settings: settings, toolchain: Toolchain(settings: settings))
        var plan = ZoomPlan(id: "t", name: "T", levelsID: LevelsProfile.smooth.id)
        let unmoved = catalog.zoomTag(plan)
        plan.setWindow(.init(finest: 0, coarsest: 4), for: ZoomFamily.named("trails")!)
        let moved = catalog.zoomTag(plan)
        XCTAssertEqual(unmoved, "", "a plan that moves nothing must not change the style")
        XCTAssertNotEqual(moved, unmoved)
        // The rungs, not the name: renaming a plan should not throw the style away.
        var renamed = plan
        renamed.name = "Something else"
        renamed.id = "other"
        XCTAssertEqual(catalog.zoomTag(renamed), moved)
    }

    /// The recipe a `kmap build` puts together carries the plan the profile named.
    @MainActor
    func testTheRecipeCarriesTheChosenPlan() async {
        let settings = SettingsStore()
        var mine = ZoomPlan(id: "mine", name: "Mine", levelsID: LevelsProfile.smooth.id)
        mine.setWindow(.init(finest: 1, coarsest: 3), for: ZoomFamily.named("woodland")!)
        let saved = settings.copyZoomPlan(mine, named: "Wiring test")
        defer { settings.deleteZoomPlan(saved.id) }

        var choices = BuildChoices()
        choices.levelsID = LevelsProfile.smooth.id
        choices.zoomPlanID = saved.id

        let region = Region(id: "x", name: "X", parentID: nil, pbfURL: nil,
                            bbox: BBox(minLon: 0, minLat: 0, maxLon: 1, maxLat: 1),
                            boxes: [], childIDs: [])
        let style = MapStyle(id: "plain", name: "Plain", summary: "", origin: .builtin,
                             styleDirectory: nil, typURL: nil, familyID: 1, productID: 1)
        var recipe = BuildRecipe(region: region, style: style,
                                 outputDirectory: URL(fileURLWithPath: "/tmp/out"))
        recipe.apply(choices, style: nil, regionCodePage: 0, plans: settings.zoomPlans)
        XCTAssertEqual(recipe.zoomPlan.id, saved.id)
        XCTAssertEqual(recipe.zoomPlan.window(ZoomFamily.named("woodland")!)?.rungs, 1...3)

        // A plan that has been deleted falls back to the built-in one rather than failing.
        settings.deleteZoomPlan(saved.id)
        recipe.apply(choices, style: nil, regionCodePage: 0, plans: settings.zoomPlans)
        XCTAssertTrue(recipe.zoomPlan.isBuiltin)
    }
}
