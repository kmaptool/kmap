import XCTest
@testable import kmap

/// The interface translates; nothing that reaches the built map does: map names, label
/// tags, file names and format tokens are identical whichever language is in use.
/// `@MainActor` because the screens are, and every test is `async` because Linux's
/// generated test list cannot name a synchronous main-actor method.
@MainActor
final class LanguageTests: XCTestCase {

    private var ctx: AppContext!
    private var languageBefore: Lang!
    private var storedBefore: String!

    override func setUp() {
        // XCTest calls this on the main thread on both platforms, but on Linux `setUp`
        // and `tearDown` are nonisolated, so the isolation has to be stated to reach
        // this class's own properties.
        MainActor.assumeIsolated {
            super.setUp()
            ctx = AppContext()
            languageBefore = L10n.current
            // These tests drive the real settings screen, which writes the real settings
            // file; the stored choice is put back in `tearDown`.
            storedBefore = ctx.settings.settings.uiLanguage
        }
    }

    override func tearDown() {
        // Nonisolated on Linux; see `setUp`.
        MainActor.assumeIsolated {
            let stored = storedBefore ?? ""
            ctx.settings.update { $0.uiLanguage = stored }
            L10n.use(languageBefore)
            super.tearDown()
        }
    }

    /// A screen has to be drawn once before what it draws can be read back.
    private func frame(_ screen: Screen, width: Int = 120, height: Int = 44) -> String {
        let surface = Surface()
        surface.resize(width, height)
        surface.clear(ctx.theme.base)
        screen.tick(ctx)
        screen.render(into: surface, rect: Rect(x: 2, y: 2, w: width - 4, h: height - 4),
                      ctx: ctx)
        return surface.compose()
    }

    // MARK: Choosing it

    func testTheLanguageFieldSwitchesTheInterfaceAndRemembersIt() async {
        let screen = SettingsScreen()
        L10n.use(.en, in: ctx.settings)
        _ = frame(screen)

        // The cursor starts on the language field, which is the first one.
        XCTAssertTrue(frame(screen).contains("Language"))
        XCTAssertTrue(frame(screen).contains("English"))

        _ = screen.handle(.right, ctx: ctx)
        XCTAssertEqual(L10n.current, .ru)
        XCTAssertEqual(ctx.settings.settings.uiLanguage, "ru",
                       "a language chosen has to survive the next launch")

        // The field's own label is drawn in the language being chosen.
        let russian = frame(screen)
        XCTAssertTrue(russian.contains("Язык"))
        XCTAssertTrue(russian.contains("Русский"))

        // Back again, the other way round the list.
        _ = screen.handle(.left, ctx: ctx)
        XCTAssertEqual(L10n.current, .en)
        XCTAssertEqual(ctx.settings.settings.uiLanguage, "en")
    }

    /// Everything a screen puts into words: title, footer hints and rendered body. The
    /// body alone can be all data, with no interface text on it.
    private func words(_ screen: Screen) -> String {
        let hints = screen.footerHints.map { "\($0.key) \($0.label)" }.joined(separator: " ")
        return screen.title + "\n" + hints + "\n" + frame(screen)
    }

    func testEveryScreenSpeaksTheLanguageInHand() async {
        let screens: [Screen] = [MainMenuScreen(), LibraryScreen(), HelpScreen(),
                                 ToolchainScreen(), SettingsScreen(), StyleListScreen(),
                                 RegionPickerScreen(),
                                 HideScreen(hidden: []) { _ in }]
        for screen in screens {
            L10n.use(.en)
            let english = words(screen)
            L10n.use(.ru)
            let russian = words(screen)
            XCTAssertNotEqual(english.count, 0)
            XCTAssertNotEqual(english, russian,
                              "\(type(of: screen)) says the same thing in both languages")
            XCTAssertTrue(russian.contains(where: { $0.isCyrillic }),
                          "\(type(of: screen)) has no Russian on it at all")
        }
    }

    func testTheTitleAndTheMenuAreTranslated() async {
        let menu = MainMenuScreen()
        L10n.use(.ru)
        XCTAssertEqual(menu.title, "меню")
        let drawn = frame(menu)
        XCTAssertTrue(drawn.contains("Новая карта"))
        XCTAssertTrue(drawn.contains("Библиотека"))
        XCTAssertTrue(drawn.contains("Стили"))
        XCTAssertTrue(drawn.contains("Настройки"))
    }

    // MARK: The keys stay where they are

    func testKeyNamesAreNeverTranslated_onlyWhatTheyDo() async {
        // A key name is a place on the keyboard, not a word: it is the same in every
        // language, while the label beside it is translated.
        let screens: [Screen] = [MainMenuScreen(), LibraryScreen(), HelpScreen(),
                                 ToolchainScreen(), SettingsScreen(), StyleListScreen(),
                                 RegionPickerScreen(),
                                 HideScreen(hidden: []) { _ in },
                                 StylePickerScreen(styles: [], current: LanguageTests.style) { _ in }]
        for screen in screens {
            L10n.use(.ru)
            _ = frame(screen)
            for hint in screen.footerHints {
                XCTAssertFalse(hint.key.contains(where: { $0.isCyrillic }),
                               "\(type(of: screen)) translated the key \"\(hint.key)\"")
            }
        }
    }

    func testTheLabelsBesideThoseKeysDoChange() async {
        let screen = LibraryScreen()
        L10n.use(.en)
        let english = screen.footerHints.map(\.label)
        L10n.use(.ru)
        let russian = screen.footerHints.map(\.label)
        XCTAssertEqual(screen.footerHints.map(\.key).count, english.count)
        XCTAssertNotEqual(english, russian)
        XCTAssertTrue(russian.contains("назад"))
    }

    // MARK: What the language may not touch

    private static let style = MapStyle(id: "borrowed", name: "Borrowed", summary: "",
                                        origin: .builtin, styleDirectory: nil, typURL: nil,
                                        familyID: 6324, productID: 1)

    private func recipe() -> BuildRecipe {
        let parent = Region(id: "continent/parent-region", name: "Parent Region",
                            parentID: "continent",
                            pbfURL: nil,
                            bbox: BBox(minLon: 9, minLat: 46, maxLon: 17, maxLat: 49),
                            boxes: [])
        let child = Region(id: "continent/parent-region/child-region", name: "Child Region",
                           parentID: "continent/parent-region", pbfURL: nil, bbox: .empty,
                           boxes: [])
        var made = BuildRecipe(region: parent, extraRegions: [child],
                               style: LanguageTests.style,
                               outputDirectory: URL(fileURLWithPath: "/tmp/out"))
        made.codePage = 1251
        made.descriptions = .phone
        return made
    }

    /// Everything the recipe decides that ends up written into the map or onto the disk.
    private func whatReachesTheMap(_ made: BuildRecipe) -> [String] {
        [made.mapName, made.familyName, made.seriesName, made.headerDescription,
         made.slug, made.outputFolderName, made.effectiveNameTagList,
         made.levels.levels, made.levels.overviewLevels,
         made.descriptions.tag ?? "-",
         made.partNames(count: 2, axis: .longitude).joined(separator: ","),
         "\(made.familyID)", "\(made.codePage)", "\(made.mapIDBase)"]
    }

    func testTheLanguageOfTheInterfaceNeverReachesTheMap() async {
        let made = recipe()
        L10n.use(.en)
        let english = whatReachesTheMap(made)
        L10n.use(.ru)
        let russian = whatReachesTheMap(made)

        XCTAssertEqual(english, russian,
                       "something the interface says is being written into the map")
        // The map's own name, spelled out rather than implied.
        XCTAssertEqual(made.mapName, "Parent Region and Child Region")
    }

    func testTheLabelLanguageOfTheMapIsNotTheLanguageOfTheInterface() async {
        // The map's label language and the interface language are separate settings.
        L10n.use(.ru)
        XCTAssertEqual(LabelLanguage.local.tagList, "")
        XCTAssertEqual(LabelLanguage.russian.tagList, "name:ru,int_name,name")
        XCTAssertEqual(LabelLanguage.english.tagList, "name:en,int_name,name")
        // The name is a word on screen and is translated; the tag list is not.
        XCTAssertEqual(LabelLanguage.russian.name, "Русские")
        L10n.use(.en)
        XCTAssertEqual(LabelLanguage.russian.name, "Russian")
        XCTAssertEqual(LabelLanguage.russian.tagList, "name:ru,int_name,name")
    }

    func testTheFormatsOwnWordsAreLeftAlone() async {
        // Section headers, rule-file names and mkgmap tags are tokens written into files,
        // and are the same in every language.
        for language in Lang.allCases {
            L10n.use(language)
            XCTAssertEqual(MapElementKind.line.typSection, "[_line]")
            XCTAssertEqual(MapElementKind.point.ruleFile, "points")
            XCTAssertEqual(MapElementKind.polygon.ruleFile, "polygons")
            XCTAssertEqual(BuildRecipe.DescriptionCarrier.phone.tag, "mkgmap:phone")
        }
        // What is on screen for the same thing does change.
        L10n.use(.ru)
        XCTAssertEqual(MapElementKind.line.plural, "линии")
        L10n.use(.en)
        XCTAssertEqual(MapElementKind.line.plural, "lines")
    }
}

private extension Character {
    var isCyrillic: Bool {
        unicodeScalars.contains { (0x0400...0x04FF).contains($0.value) }
    }
}
