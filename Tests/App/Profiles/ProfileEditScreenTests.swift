import XCTest

@testable import kmap

/// A profile opened and left is saved as it was: its own zoom plan and its style kept,
/// whatever the form could find of them.
@MainActor
final class ProfileEditScreenTests: XCTestCase {
    private var ctx: AppContext!
    private var made: [String] = []

    override func setUp() async throws {
        ctx = AppContext()
    }

    override func tearDown() async throws {
        for id in made { _ = ctx.settings.deleteProfile(id) }
    }

    private func profile(_ choices: BuildChoices) -> BuildProfile {
        let profile = ctx.settings.addProfile(named: "edit-\(UUID().uuidString.prefix(8))", choices: choices)
        made.append(profile.id)
        return profile
    }

    /// Ticks a form until its style scan is over.
    private func scanned(_ tick: () -> Void, _ form: () -> RecipeForm?) {
        for _ in 0..<500 {
            tick()
            if let form = form(), !form.scanningStyles, !form.styleChoices.isEmpty { return }
            Thread.sleep(forTimeInterval: 0.01)
        }
    }

    private func form(for profile: BuildProfile) -> RecipeForm {
        var recipe = BuildRecipe(
            region: Region(id: "x", name: "X", parentID: nil, pbfURL: nil, bbox: .empty, boxes: []),
            style: .standIn,
            outputDirectory: FileManager.default.temporaryDirectory
        )
        recipe.apply(profile.choices, style: nil, regionCodePage: 1252, plans: ctx.settings.zoomPlans)
        let form = RecipeForm(mode: .build, recipe: recipe, regionCodePage: 1252, askedStyleID: profile.choices.styleID)
        form.profiles = ctx.settings.profiles
        form.currentProfileID = profile.id
        scanned({ form.tick(ctx) }, { form })
        return form
    }

    func testAProfilesOwnZoomPlanIsKept() async throws {
        let mine = ctx.settings.copyZoomPlan(ZoomPlan.builtins[0], named: "kept plan")
        defer { _ = ctx.settings.deleteZoomPlan(mine.id) }
        var choices = BuildChoices()
        choices.levelsID = mine.levelsID
        choices.zoomPlanID = mine.id
        let alps = profile(choices)

        let form = form(for: alps)
        XCTAssertEqual(form.recipe.zoomPlan.id, mine.id)
        XCTAssertFalse(form.isModified)

        let screen = ProfileEditScreen(profile: alps, settings: ctx.settings, hasSeamPatch: false)
        screen.tick(ctx)
        _ = screen.handle(.esc, ctx: ctx)
        XCTAssertEqual(ctx.settings.profile(alps.id)?.choices.zoomPlanID, mine.id)
    }

    func testAMissingStyleIsSaidAndKept() async throws {
        var choices = BuildChoices()
        choices.styleID = "typ:gone-away"
        let alps = profile(choices)

        let form = form(for: alps)
        XCTAssertEqual(form.missingStyleID, "typ:gone-away")
        XCTAssertTrue(form.value(for: .style).contains("typ:gone-away"))

        let screen = ProfileEditScreen(profile: alps, settings: ctx.settings, hasSeamPatch: false)
        for _ in 0..<500 where ctx.styles.styles().scanning {
            screen.tick(ctx)
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        screen.tick(ctx)
        _ = screen.handle(.esc, ctx: ctx)
        XCTAssertEqual(ctx.settings.profile(alps.id)?.choices.styleID, "typ:gone-away")
    }

    /// A save the file refuses keeps the screen; only the same key, straight away, leaves.
    func testARefusedSaveLeavesOnlyOnTheSameKeyAgain() async throws {
        let alps = profile(BuildChoices())
        let screen = ProfileEditScreen(profile: alps, settings: ctx.settings, hasSeamPatch: false)
        screen.tick(ctx)
        let file = Paths.settingsFile
        let kept = try? Data(contentsOf: file)
        FileTools.removeIfPresent(file)
        try FileManager.default.createDirectory(at: file, withIntermediateDirectories: true)
        defer {
            FileTools.removeIfPresent(file)
            if let kept { try? FileTools.write(kept, to: file) }
        }

        func stays(_ key: KeyEvent) -> Bool {
            if case .none = screen.handle(key, ctx: ctx) { return true }
            return false
        }
        XCTAssertTrue(stays(.esc))
        XCTAssertTrue(stays(.ctrl("c")), "another key asks again")
        _ = screen.handle(.down, ctx: ctx)
        XCTAssertTrue(stays(.ctrl("c")), "not straight after its refusal")
        if case .quit = screen.handle(.ctrl("c"), ctx: ctx) {} else { XCTFail("the same key again leaves") }
    }
}
