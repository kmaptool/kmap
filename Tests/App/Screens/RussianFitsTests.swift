import XCTest
@testable import kmap

/// Renders every screen in both languages and asks the surface what it had to cut short.
/// A string clipped in Russian but not in English is a translation that needs shortening
/// or a column that needs widening; the drawing loop reports neither on its own.
final class RussianFitsTests: XCTestCase {

    private var ctx: AppContext!

    @MainActor
    override func setUp() async throws {
        ctx = AppContext()
    }

    /// Terminal sizes worth fitting; the second is a narrow split pane.
    private static let sizes = [(110, 40), (80, 30)]

    @MainActor
    private func clipped(_ make: () -> Screen, width: Int, height: Int) -> [Surface.Clip] {
        let (_, found) = Surface.collectClipped { () -> Void in
            let screen = make()
            let surface = Surface()
            surface.resize(width, height)
            surface.clear(ctx.theme.base)
            screen.tick(ctx)
            screen.render(into: surface,
                          rect: Rect(x: 2, y: 2, w: width - 4, h: height - 4), ctx: ctx)
        }
        return found
    }

    /// Every screen that draws without being handed something first.
    @MainActor
    private var screens: [(String, () -> Screen)] {
        [("main menu", { MainMenuScreen() }),
         ("settings", { SettingsScreen() }),
         ("toolchain", { ToolchainScreen() }),
         ("profiles", { ProfilesScreen() }),
         ("styles", { StyleListScreen() }),
         ("hide", { HideScreen(hidden: [], onChange: { _ in }) }),
         ("help", { HelpScreen() }),
         ("library", { LibraryScreen() }),
         // The screens that need something handed to them; the region is made up, since
         // what is measured is the layout and not the data.
         ("new map", { [ctx] in
             RecipeScreen(region: Self.somewhere, settings: ctx!.settings,
                          hasSeamPatch: true) }),
         ("profile", { [ctx] in
             ProfileEditScreen(profile: BuildProfile(id: "test", name: "Профиль",
                                                     choices: BuildChoices()),
                               settings: ctx!.settings, hasSeamPatch: true) })]
    }

    /// A region whose name is long enough to be worth drawing.
    private static let somewhere = Region(
        id: "large-region", name: "Large Inland Region",
        parentID: nil, pbfURL: nil,
        bbox: BBox(minLon: 32.15, minLat: 43.18, maxLon: 36.68, maxLat: 46.25),
        boxes: [], childIDs: [])

    @MainActor
    func testNothingIsCutShortInRussianThatFitsInEnglish() async {
        let was = L10n.current
        defer { L10n.use(was) }

        var complaints: [String] = []
        for (width, height) in Self.sizes {
            for (name, make) in screens {
                L10n.use(.en)
                let english = Set(clipped(make, width: width, height: height))
                L10n.use(.ru)
                let russian = Set(clipped(make, width: width, height: height))
                // A string cut in both languages is a layout that is always too tight,
                // and not this test's business.
                let onlyRussian = russian.subtracting(english)
                for clip in onlyRussian.sorted(by: { ($0.y, $0.x) < ($1.y, $1.x) }) {
                    complaints.append("\(name) at \(width)x\(height), row \(clip.y): \(clip.text)")
                }
            }
        }
        XCTAssertTrue(complaints.isEmpty,
                      "cut short in Russian:\n  " + complaints.joined(separator: "\n  "))
    }
}

extension RussianFitsTests {
    /// Writes every screen's rendering to a temporary directory when `KMAP_SHOW_SCREENS`
    /// is set in the environment. Asserts nothing.
    @MainActor
    func testShowTheScreens() async {
        guard ProcessInfo.processInfo.environment["KMAP_SHOW_SCREENS"] != nil else { return }
        let was = L10n.current
        defer { L10n.use(was) }
        for language in [Lang.en, .ru] {
            L10n.use(language)
            for (name, make) in screens {
                let surface = Surface()
                surface.resize(110, 40)
                surface.clear(ctx.theme.base)
                let screen = make()
                screen.tick(ctx)
                screen.render(into: surface, rect: Rect(x: 2, y: 2, w: 106, h: 36), ctx: ctx)
                let file = URL(fileURLWithPath: NSTemporaryDirectory())
                    .appendingPathComponent("kmap-screens")
                try? FileManager.default.createDirectory(
                    at: file, withIntermediateDirectories: true)
                try? surface.asText().write(
                    to: file.appendingPathComponent(
                        "\(name.replacingOccurrences(of: " ", with: "-"))-\(language.rawValue).txt"),
                    atomically: true, encoding: .utf8)
            }
        }
    }
}

/// Every screen declares one `Page`, and its title and keys are the ones the screen
/// itself reports.
final class PageTests: XCTestCase {

    private var ctx: AppContext!

    @MainActor
    override func setUp() async throws {
        ctx = AppContext()
    }

    @MainActor
    func testEveryScreenNamesItselfAndOffersKeys() async {
        let screens: [(String, Screen)] = [
            ("main menu", MainMenuScreen()), ("settings", SettingsScreen()),
            ("toolchain", ToolchainScreen()), ("profiles", ProfilesScreen()),
            ("styles", StyleListScreen()), ("help", HelpScreen()),
            ("library", LibraryScreen()),
            ("hide", HideScreen(hidden: [], onChange: { _ in })),
        ]
        for (name, screen) in screens {
            XCTAssertFalse(screen.page.name.isEmpty, "\(name) has no name")
            XCTAssertFalse(screen.page.keys.isEmpty, "\(name) offers no keys")
            XCTAssertEqual(screen.title, screen.page.title)
            XCTAssertEqual(screen.footerHints.count, screen.page.keys.count)
        }
    }

    /// A subject is joined to the page's name the same way everywhere; an empty or absent
    /// subject leaves no separator behind.
    func testTheSubjectIsJoinedTheSameWayEverywhere() {
        XCTAssertEqual(Page("styles").title, "styles")
        XCTAssertEqual(Page("styles", subject: "search").title, "styles · search")
        XCTAssertEqual(Page("styles", subject: nil).title, "styles")
        XCTAssertEqual(Page("styles", subject: "").title, "styles",
                       "an empty subject is no subject, not a trailing dot")
    }
}
