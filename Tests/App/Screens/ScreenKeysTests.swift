import XCTest
@testable import kmap

/// Every key a screen advertises in its footer does something: each is pressed against a
/// settled screen. `@MainActor` because the screens are, and every test is `async` because
/// Linux's generated test list cannot name a synchronous main-actor method.
@MainActor
final class ScreenKeysTests: XCTestCase {

    private var library: URL!
    private var style: MapStyle!
    private var ctx: AppContext!

    override func setUpWithError() throws {
        // On Linux `setUp` is nonisolated, so the isolation has to be stated to reach
        // this class's own properties.
        try MainActor.assumeIsolated {
            ctx = AppContext()

            // These screens drive the real library, so both folders are swept afterwards:
            // an original is not a style, but the import screen compares against it.
            let originals = TypLibrary.originalsDirectory()
            let before = Set((TypLibrary.contents() + TypLibrary.contents(in: originals))
                .map(\.lastPathComponent))
            addTeardownBlock {
                for url in TypLibrary.contents() + TypLibrary.contents(in: originals)
                where !before.contains(url.lastPathComponent) {
                    try? FileManager.default.removeItem(at: url)
                }
            }

            library = try TypLibrary.adopt(source: TypFixture.source,
                                           named: "zz-screen-keys-\(UUID().uuidString.prefix(8))")
            style = try XCTUnwrap(StyleCatalog.libraryStyle(at: library))
        }
    }

    private func select(_ screen: Screen, steps: Int) {
        for _ in 0..<steps { _ = screen.handle(.down, ctx: ctx) }
    }

    /// Renders `screen` once: several build their row list lazily, and a key pressed
    /// against an unrendered screen reaches nothing.
    private func settle(_ screen: Screen, width: Int = 110, height: Int = 40) {
        let surface = Surface()
        surface.resize(width, height)
        surface.clear(ctx.theme.base)
        screen.tick(ctx)
        screen.render(into: surface, rect: Rect(x: 2, y: 2, w: width - 4, h: height - 4),
                      ctx: ctx)
    }

    private func pushed(_ route: Route) -> Screen? {
        if case .push(let screen) = route { return screen }
        return nil
    }

    // MARK: The styles list

    /// Enter opens the style under the cursor.
    func testEnterOpensAStyleFromTheList() async throws {
        let screen = StyleListScreen()
        settle(screen)
        let route = screen.handle(.enter, ctx: ctx)
        XCTAssertTrue(pushed(route) is StyleDetailScreen,
                      "Enter is advertised as \"open\" and must open something")
    }

    func testTheStylesListAdvertisesNoKeyThatDoesNothing() async throws {
        let screen = StyleListScreen()
        settle(screen)

        // `i` and `n` navigate; `/`, `r`, `d` and `m` change the screen's own state. Each
        // is pressed on a fresh screen so one does not mask another.
        XCTAssertTrue(pushed(StyleListScreen().alsoSettled(self).handle(.char("i"), ctx: ctx))
                        is ImportTypScreen, "i")
        XCTAssertTrue(pushed(StyleListScreen().alsoSettled(self).handle(.char("n"), ctx: ctx))
                        is StyleDetailScreen, "n creates a style and opens it")

        // The state-changing ones show in the footer.
        let searching = StyleListScreen().alsoSettled(self)
        _ = searching.handle(.char("/"), ctx: ctx)
        XCTAssertTrue(searching.footerHints.contains { $0.label == "clear" },
                      "/ should start a search")

        // Both refuse a style that is not editable, so the cursor has to be on the
        // fixture adopted in `setUp`.
        let deleting = StyleListScreen().alsoSettled(self)
        selectOwnStyle(in: deleting)
        _ = deleting.handle(.char("d"), ctx: ctx)
        XCTAssertTrue(deleting.footerHints.contains { $0.label == "keep it" },
                      "d should ask before deleting")

        let renaming = StyleListScreen().alsoSettled(self)
        selectOwnStyle(in: renaming)
        _ = renaming.handle(.char("r"), ctx: ctx)
        XCTAssertTrue(renaming.footerHints.contains { $0.label == "cancel" },
                      "r should start a rename")
    }

    /// Copying a style adds one entry and leaves the file it was copied from in place.
    func testCopyingAStyleLeavesTheOriginalAlone() async throws {
        let screen = StyleListScreen()
        settle(screen)
        let before = Set(TypLibrary.contents())
        selectLibraryStyle(screen)
        _ = screen.handle(.char("c"), ctx: ctx)

        let added = Set(TypLibrary.contents()).subtracting(before)
        XCTAssertEqual(added.count, 1, "a copy is one more entry, not one changed entry")
        XCTAssertTrue(added.first?.lastPathComponent.hasPrefix("zz-screen-keys") == true,
                      "and it is a copy of this test's own style: \(added)")
        XCTAssertTrue(FileTools.exists(library), "the style it was copied from is there")
    }

    func testRestoringAsksBeforeItRewritesAnything() async throws {
        let imported = try importedStyle()
        let file = try XCTUnwrap(imported.typURL)
        let asImported = try String(contentsOf: file, encoding: .utf8)
        try (asImported + "\n; edited since\n").write(to: file, atomically: true,
                                                       encoding: .utf8)

        let screen = StyleListScreen()
        selectLibraryStyle(screen, named: imported.name)
        _ = screen.handle(.char("o"), ctx: ctx)

        // The question is up, and nothing has happened yet.
        XCTAssertTrue(screen.footerHints.contains { $0.key == "←→" }, "o should ask first")
        XCTAssertTrue(try String(contentsOf: file, encoding: .utf8).contains("edited since"))

        // The cursor starts on the answer that changes nothing.
        _ = screen.handle(.enter, ctx: ctx)
        XCTAssertTrue(try String(contentsOf: file, encoding: .utf8).contains("edited since"),
                      "leaning on Enter must not overwrite somebody's work")

        // Agreed to, it goes back to what was imported.
        _ = screen.handle(.char("o"), ctx: ctx)
        _ = screen.handle(.right, ctx: ctx)
        _ = screen.handle(.enter, ctx: ctx)
        XCTAssertFalse(try String(contentsOf: file, encoding: .utf8).contains("edited since"))
    }

    func testRestoringSaysSoWhereThereIsNothingKeptToGoBackTo() async throws {
        // This entry was adopted rather than imported, so no binary is kept beside it.
        XCTAssertNil(TypLibrary.original(of: library))

        let screen = StyleListScreen()
        selectLibraryStyle(screen)
        _ = screen.handle(.char("o"), ctx: ctx)

        XCTAssertFalse(screen.footerHints.contains { $0.key == "←→" },
                       "there is nothing to ask about")

        let surface = Surface()
        surface.resize(110, 40)
        surface.clear(ctx.theme.base)
        screen.render(into: surface, rect: Rect(x: 2, y: 2, w: 106, h: 36), ctx: ctx)
        XCTAssertTrue(surface.compose().contains(t("this style has no original kept — nothing"
                                                 + " was imported to go back to")))
    }

    /// Narrows the list to the entry this test created and puts the cursor on it.
    private func selectLibraryStyle(_ screen: StyleListScreen, named name: String? = nil) {
        settle(screen)
        _ = screen.handle(.char("/"), ctx: ctx)
        for c in name ?? style.name { _ = screen.handle(.char(c), ctx: ctx) }
        _ = screen.handle(.enter, ctx: ctx)
        settle(screen)
    }

    /// A style with the original binary kept beside it. Imported rather than adopted,
    /// because only an import keeps one.
    private func importedStyle() throws -> MapStyle {
        var bytes = [UInt8](repeating: 0, count: 0x60)
        bytes[0] = 0x5B
        for (i, b) in Array("GARMIN TYP".utf8).enumerated() { bytes[2 + i] = b }
        bytes[0x2F] = 0x2A                                   // family 42
        bytes[0x31] = 0x01
        let source = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("zz-keys-import-\(UUID().uuidString.prefix(6)).typ")
        try Data(bytes).write(to: source)
        addTeardownBlock { try? FileManager.default.removeItem(at: source) }

        let taken = try TypLibrary.take(at: source)
        return try XCTUnwrap(StyleCatalog.libraryStyle(at: taken.url))
    }

    func testTheStylesListReachesItsCommandsFromARussianLayout() async {
        let screen = StyleListScreen().alsoSettled(self)
        // `ш` sits where `i` does.
        XCTAssertTrue(pushed(screen.handle(.char("ш"), ctx: ctx)) is ImportTypScreen)
    }

    /// Walks the cursor to the style this test adopted.
    private func selectOwnStyle(in screen: StyleListScreen) {
        let styles = ctx.styles.styles().list
        // By resolved path: the temporary directory is reached through a symlink, and both
        // spellings of it occur.
        let wanted = library.resolvingSymlinksInPath()
        guard let index = styles.firstIndex(where: {
            $0.typURL?.resolvingSymlinksInPath() == wanted
        }) else { return XCTFail("the adopted style is not in the list") }
        select(screen, steps: index)
    }

    // MARK: The type browser

    func testEnterOpensATypeThatHasASection() async throws {
        let document = StyleDocument.load(style)
        _ = try XCTUnwrap(document.rows(.polygon).first { $0.isStyled },
                      "the fixture must style at least one polygon")

        // Walked with the screen's own keys rather than by row index: the screen folds
        // runs of anonymous codes, so its list is shorter than the document's.
        let screen = TypeBrowserScreen(document: document, kind: .polygon)
        settle(screen)
        var opened = false
        for _ in 0..<300 {
            if pushed(screen.handle(.enter, ctx: ctx)) is TypeEditScreen {
                opened = true
                break
            }
            _ = screen.handle(.down, ctx: ctx)
        }
        XCTAssertTrue(opened, "some styled polygon should open the editor")
    }

    /// `x` on a free code opens the inverse flow: pick a feature to bind here.
    func testReassignOnAFreeCodeAsksWhichFeatureToBindThere() async throws {
        let document = StyleDocument.load(style)
        let rows = document.rows(.polygon)
        let free = try XCTUnwrap(rows.last { !$0.isEmitted && !$0.isStyled },
                                 "the polygon space always has free codes")
        let screen = TypeBrowserScreen(document: document, kind: .polygon)
        settle(screen)
        _ = free
        // Walk to the bottom; `x` on a fold unfolds it first, so a few tries reach a
        // concrete free row whatever the folding did.
        var opened: Screen?
        for _ in 0..<5 {
            _ = screen.handle(.end, ctx: ctx)
            if let p = pushed(screen.handle(.char("x"), ctx: ctx)) { opened = p; break }
        }
        XCTAssertTrue(opened is ReassignScreen)
    }

    /// Enter refuses a type the TYP does not style.
    func testEnterOnAnUnstyledTypeSaysToAddASectionInstead() async throws {
        // Needs a materialized rule set to compare the TYP against, which is built on
        // first use.
        try XCTSkipUnless(FileTools.exists(Paths.styles.appendingPathComponent("points")),
                          "no materialized style — build once first")
        let document = StyleDocument.load(style)
        let rows = document.rows(.polygon)
        let index = try XCTUnwrap(rows.firstIndex { !$0.isStyled },
                                  "the rule set must emit something this TYP misses")

        let screen = TypeBrowserScreen(document: document, kind: .polygon)
        settle(screen)
        select(screen, steps: index)
        XCTAssertNil(pushed(screen.handle(.enter, ctx: ctx)))
    }

    func testTheBrowserAdvertisesNoKeyThatDoesNothing() async throws {
        let document = StyleDocument.load(style)

        let searching = TypeBrowserScreen(document: document, kind: .polygon)
        settle(searching)
        _ = searching.handle(.char("/"), ctx: ctx)
        XCTAssertTrue(searching.footerHints.contains { $0.label == "clear" }, "/")

        // The pane under the list, which starts closed.
        let preview = TypeBrowserScreen(document: document, kind: .polygon)
        settle(preview)
        let closed = preview.footerHints.first { $0.key == "p" }?.label
        _ = preview.handle(.char("p"), ctx: ctx)
        XCTAssertNotEqual(preview.footerHints.first { $0.key == "p" }?.label, closed,
                          "p should open and close the preview")

        let language = TypeBrowserScreen(document: document, kind: .polygon)
        settle(language)
        let before = language.footerHints.first { $0.key == "l" }?.label
        _ = language.handle(.char("l"), ctx: ctx)
        XCTAssertNotEqual(language.footerHints.first { $0.key == "l" }?.label, before,
                          "l should swap the language")

        // `x` reassigns a rule, which needs a code the rule set emits.
        let reassign = TypeBrowserScreen(document: document, kind: .polygon)
        settle(reassign)
        if document.rules != nil {
            let route = reassign.handle(.char("x"), ctx: ctx)
            XCTAssertTrue(pushed(route) is ReassignScreen || pushed(route) == nil,
                          "x should either open the reassign screen or refuse with a reason")
        }
    }

    func testTheArrowsMoveBetweenPointsLinesAndPolygons() async {
        let screen = TypeBrowserScreen(document: StyleDocument.load(style), kind: .point)
        settle(screen)
        XCTAssertTrue(screen.title.contains("point"))
        _ = screen.handle(.right, ctx: ctx)
        XCTAssertTrue(screen.title.contains("line"), screen.title)
        _ = screen.handle(.left, ctx: ctx)
        XCTAssertTrue(screen.title.contains("point"), screen.title)
    }

    /// Every field that holds a path offers the browse key, and only where a file dialog
    /// is available.
    func testThePathFieldsOfferBrowsingWhereThereIsSomethingToBrowseWith() async {
        let importer = ImportTypScreen(onImported: {})
        settle(importer)
        _ = importer.handle(.tab, ctx: ctx)                    // into path mode
        XCTAssertEqual(importer.footerHints.contains { $0.key == "^O" },
                       FilePicker.isAvailable)

        let settings = SettingsScreen()
        settle(settings)
        _ = settings.handle(.down, ctx: ctx)                   // off the language, onto output
        _ = settings.handle(.enter, ctx: ctx)                  // into the field
        XCTAssertEqual(settings.footerHints.contains { $0.key == "^O" },
                       FilePicker.isAvailable)
        _ = settings.handle(.esc, ctx: ctx)
    }

    func testABrowseKeyIsNotOfferedWhereAPathIsNotWanted() async {
        // The language is a choice from a list, not a place on the disk.
        let settings = SettingsScreen()
        settle(settings)
        _ = settings.handle(.enter, ctx: ctx)                  // opens the language list
        XCTAssertFalse(settings.footerHints.contains { $0.key == "^O" })
    }

    // MARK: Settings

    /// The language field opens the list of languages rather than cycling through them,
    /// and a choice applies at once and is stored.
    func testTheLanguageFieldOpensAListToPickFrom() async {
        let was = L10n.current
        let stored = ctx.settings.settings.uiLanguage
        let settings = ctx.settings
        addTeardownBlock { @MainActor in
            settings.update { $0.uiLanguage = stored }
            L10n.use(was)
        }

        let screen = SettingsScreen()
        settle(screen)
        XCTAssertFalse(screen.footerHints.contains { $0.label == "choose" })

        _ = screen.handle(.enter, ctx: ctx)
        XCTAssertTrue(screen.footerHints.contains { $0.label == "choose" },
                      "⏎ on the language should open the list")

        // Escape leaves the language where it was; the list is a choice, not a change.
        _ = screen.handle(.down, ctx: ctx)
        _ = screen.handle(.esc, ctx: ctx)
        XCTAssertEqual(L10n.current, was)
        XCTAssertFalse(screen.footerHints.contains { $0.label == "choose" })

        // Choosing applies it at once, and the field's own label is drawn in it.
        _ = screen.handle(.enter, ctx: ctx)
        _ = screen.handle(.down, ctx: ctx)
        _ = screen.handle(.enter, ctx: ctx)
        XCTAssertNotEqual(L10n.current, was)
        XCTAssertEqual(ctx.settings.settings.uiLanguage, L10n.current.rawValue,
                       "a language chosen has to survive the next launch")
    }

    /// Every setting whose answer is one of a handful opens the same list; a field holding
    /// a path does not.
    func testTheNumericSettingsOpenTheSameListAsTheLanguage() async {
        let stored = ctx.settings.settings
        let settings = ctx.settings
        addTeardownBlock { @MainActor in settings.update { $0 = stored } }

        // Down from the language: output, work, streams. Walk to the streams field.
        let screen = SettingsScreen()
        settle(screen)
        var steps = 0
        while steps < 12 {
            _ = screen.handle(.enter, ctx: ctx)
            if screen.footerHints.contains(where: { $0.label == "choose" }) { break }
            _ = screen.handle(.esc, ctx: ctx)
            _ = screen.handle(.down, ctx: ctx)
            steps += 1
        }
        _ = screen.handle(.esc, ctx: ctx)

        // Streams, heap and nodes-per-tile all offer a list.
        for field in [SettingsScreen.Field.connections, .toolchainUpdates, .heap,
                      .maxNodes, .keepWork] {
            XCTAssertNotNil(SettingsScreen().dropdownForTesting(field, ctx),
                            "\(field) should offer a list")
        }
        // A folder is typed, not chosen from one.
        XCTAssertNil(SettingsScreen().dropdownForTesting(.output, ctx))
        XCTAssertNil(SettingsScreen().dropdownForTesting(.mkgmapJar, ctx))
    }

    // MARK: Updating a data pack by hand

    /// A coastline pack in this run's own root, so the list has a row to press keys on.
    /// The real one lives under the real ~/.kmap and is never touched by a test.
    private func installFakeSeaPack() throws {
        Paths.ensure(Paths.tools)
        try Data(repeating: 0, count: 2_000_000).write(to: Paths.seaData)
        addTeardownBlock { FileTools.removeIfPresent(Paths.seaData) }
    }

    /// The toolchain list is probed off the render loop; these tests need it settled.
    private func settledToolchain(_ screen: ToolchainScreen) async -> Bool {
        screen.tick(ctx)
        for _ in 0..<200 where !ctx.toolsProbed {
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return ctx.toolsProbed
    }

    /// `u` is for the two packs that go out of date while installed. Everything else in
    /// the list is a program with a version, and kmap does not chase those.
    func testUpdatingSomethingThatIsNotADataPackSaysSo() async {
        let screen = ToolchainScreen()
        guard await settledToolchain(screen) else { return XCTFail("the list never settled") }
        ctx.useForTesting(packNews: [:])
        guard let mkgmap = ctx.tools.firstIndex(where: { $0.id == "mkgmap" }) else {
            return XCTFail("the toolchain list always names mkgmap")
        }
        select(screen, steps: mkgmap)
        _ = screen.handle(.char("u"), ctx: ctx)
        XCTAssertEqual(screen.messageForTesting, t("%@ is not something kmap updates", "mkgmap"))
    }

    /// A pack the mirror still publishes as it is: nothing is fetched, and the screen says
    /// why rather than going quiet.
    func testUpdatingAPackWithNoNewsFetchesNothing() async throws {
        try installFakeSeaPack()
        let screen = ToolchainScreen()
        _ = await settledToolchain(screen)
        ctx.useForTesting(packNews: [:])
        let row = try XCTUnwrap(ctx.tools.firstIndex { $0.id == "sea" })
        select(screen, steps: row)
        _ = screen.handle(.char("u"), ctx: ctx)
        XCTAssertNil(screen.installingForTesting, "nothing to fetch")
        XCTAssertEqual(screen.messageForTesting,
                       t("%@ is already the published one",
                         ctx.tools[row].name))
    }

    /// And one the mirror has moved on from: the fetch starts.
    func testUpdatingAPackWithNewsStartsTheFetch() async throws {
        try installFakeSeaPack()
        let screen = ToolchainScreen()
        _ = await settledToolchain(screen)
        ctx.useForTesting(packNews: ["sea": DataPack.News(size: 343_858_019,
                                                          lastModified: nil,
                                                          published: Date())])
        let row = try XCTUnwrap(ctx.tools.firstIndex { $0.id == "sea" })
        // The decision, not the download: pressing the key here would fetch 344 MB.
        XCTAssertEqual(screen.updateAction(for: ctx.tools[row], ctx), .fetch)
    }

    /// Choosing from the list writes the value, and the list shows where it already is.
    func testChoosingFromTheListSetsTheValue() async {
        let stored = ctx.settings.settings
        let settings = ctx.settings
        addTeardownBlock { @MainActor in settings.update { $0 = stored } }

        settings.update { $0.maxNodesPerTile = SettingsScreen.nodeChoices[0] }
        let screen = SettingsScreen()
        XCTAssertEqual(screen.dropdownForTesting(.maxNodes, ctx)?.at, 0,
                       "the list opens on the value in force")
        screen.chooseForTesting(.maxNodes, at: 3, ctx)
        XCTAssertEqual(ctx.settings.settings.maxNodesPerTile, SettingsScreen.nodeChoices[3])

        // The toolchain cadence is a list of six, and choosing writes the one chosen.
        settings.update { $0.toolchainUpdates = .monthly }
        XCTAssertEqual(screen.dropdownForTesting(.toolchainUpdates, ctx)?.labels.count, 6)
        XCTAssertEqual(screen.dropdownForTesting(.toolchainUpdates, ctx)?.at,
                       ToolchainUpdates.allCases.firstIndex(of: .monthly))
        screen.chooseForTesting(.toolchainUpdates,
                                at: ToolchainUpdates.allCases.firstIndex(of: .never)!, ctx)
        XCTAssertEqual(ctx.settings.settings.toolchainUpdates, .never)

        settings.update { $0.javaHeapGB = 0 }
        XCTAssertEqual(screen.dropdownForTesting(.heap, ctx)?.at, 0)
        XCTAssertTrue(screen.dropdownForTesting(.heap, ctx)?.labels.first?.contains("auto") ?? false,
                      "a heap of nothing reads as automatic, with the size it worked out")
        screen.chooseForTesting(.heap, at: 4, ctx)
        XCTAssertEqual(ctx.settings.settings.javaHeapGB, SettingsScreen.heapChoices[4])

        screen.chooseForTesting(.keepWork, at: 1, ctx)
        XCTAssertTrue(ctx.settings.settings.keepWorkFiles)
        screen.chooseForTesting(.keepWork, at: 0, ctx)
        XCTAssertFalse(ctx.settings.settings.keepWorkFiles)
    }

    /// The list is drawn over the form, against the field it belongs to.
    func testTheOpenLanguageListIsOnScreen() async {
        let was = L10n.current
        let stored = ctx.settings.settings.uiLanguage
        let settings = ctx.settings
        addTeardownBlock { @MainActor in
            settings.update { $0.uiLanguage = stored }
            L10n.use(was)
        }
        L10n.use(.en, in: ctx.settings)

        let screen = SettingsScreen()
        settle(screen)
        _ = screen.handle(.enter, ctx: ctx)

        let surface = Surface()
        surface.resize(110, 40)
        surface.clear(ctx.theme.base)
        let rect = Rect(x: 2, y: 2, w: 106, h: 36)
        screen.render(into: surface, rect: rect, ctx: ctx)
        // Both passes, the way the app draws: an open list is an overlay.
        screen.renderOverlay(into: surface, rect: rect, ctx: ctx)
        let drawn = surface.compose()
        for language in Lang.allCases {
            XCTAssertTrue(drawn.contains(language.nativeName),
                          "\(language.nativeName) has to be in the open list")
        }
    }

    // MARK: The type editor

    func testEnterOnTheDrawingRowOpensSomethingToChooseADrawingWith() async {
        let screen = TypeEditScreen(style: style, kind: .point, code: 0x2a00, onEdited: {})
        settle(screen)
        XCTAssertTrue(pushed(screen.handle(.enter, ctx: ctx)) is IconDonorScreen)
    }

    func testEnterOnTheDrawRowOpensThePixelEditor() async {
        let screen = TypeEditScreen(style: style, kind: .point, code: 0x2a00, onEdited: {})
        settle(screen)
        _ = screen.handle(.down, ctx: ctx)
        XCTAssertTrue(pushed(screen.handle(.enter, ctx: ctx)) is PixelEditorScreen)
    }

    /// Left and right choose which half of a colour pair is being worked on, and the footer
    /// says so only while the cursor is on one.
    func testTheEditorOffersDayAndNightOnAColourRow() async {
        let screen = TypeEditScreen(style: style, kind: .line, code: 0x07, onEdited: {})
        settle(screen)
        _ = screen.handle(.down, ctx: ctx)
        _ = screen.handle(.down, ctx: ctx)
        XCTAssertTrue(screen.footerHints.contains { $0.label == "day / night" },
                      "\(screen.footerHints.map(\.label))")
    }

    // MARK: The pixel editor

    func testSpacePaintsAndUndoPutsItBack() async throws {
        let screen = try XCTUnwrap(PixelEditorScreen(style: style, kind: .point,
                                                     code: 0x2a00, onSaved: {}))
        settle(screen)
        XCTAssertFalse(screen.title.hasSuffix("·"), "nothing changed yet")

        _ = screen.handle(.char("]"), ctx: ctx)   // a different colour
        _ = screen.handle(.char(" "), ctx: ctx)   // paint with it
        XCTAssertTrue(screen.title.hasSuffix("·"), "space should paint")

        _ = screen.handle(.char("u"), ctx: ctx)
        XCTAssertFalse(screen.title.hasSuffix("·"), "u should undo it")
    }

    /// Adding a colour and changing one both take a hex, and both offer the palette picker.
    func testThePixelEditorOffersAPickerWhereAColourIsWanted() async throws {
        let screen = try XCTUnwrap(PixelEditorScreen(style: style, kind: .point,
                                                     code: 0x2a00, onSaved: {}))
        settle(screen)
        _ = screen.handle(.char("a"), ctx: ctx)
        XCTAssertTrue(screen.footerHints.contains { $0.key == "^P" },
                      "adding a colour should offer the picker")

        _ = screen.handle(.ctrl("p"), ctx: ctx)
        XCTAssertTrue(screen.footerHints.contains { $0.label == "take it" },
                      "^P should open it")

        _ = screen.handle(.esc, ctx: ctx)
        XCTAssertFalse(screen.footerHints.contains { $0.label == "take it" },
                       "esc should go back to typing, not out of the prompt")
    }

    /// The size prompt does not offer the colour picker.
    func testThePickerIsNotOfferedWhereAColourIsNotWanted() async throws {
        let screen = try XCTUnwrap(PixelEditorScreen(style: style, kind: .point,
                                                     code: 0x2a00, onSaved: {}))
        settle(screen)
        _ = screen.handle(.char("s"), ctx: ctx)
        XCTAssertFalse(screen.footerHints.contains { $0.key == "^P" })
    }

    /// A pointer move moves the cursor without painting, so the readout under the canvas
    /// can be aimed at a pixel.
    func testMovingThePointerMovesTheCursorWithoutPainting() async throws {
        let screen = try XCTUnwrap(PixelEditorScreen(style: style, kind: .point,
                                                     code: 0x2a00, onSaved: {}))
        settle(screen)
        let event = MouseEvent(action: .move, x: 2 + 3 + 5 * 2, y: 2 + 1 + 1 + 4,
                               isPrimary: false)
        _ = screen.handle(.mouse(event), ctx: ctx)
        XCTAssertFalse(screen.title.hasSuffix("·"), "hovering must not change the picture")
    }

    /// The cursor and the colour list both take the arrow keys; tab says which has them.
    func testTabMovesBetweenThePictureAndTheColourList() async throws {
        let screen = try XCTUnwrap(PixelEditorScreen(style: style, kind: .point,
                                                     code: 0x2a00, onSaved: {}))
        settle(screen)
        XCTAssertTrue(screen.footerHints.contains { $0.label == "choose a colour" })

        _ = screen.handle(.tab, ctx: ctx)
        XCTAssertTrue(screen.footerHints.contains { $0.label == "the colour you paint with" },
                      "tab should hand the arrows to the colour list")

        // There the arrows change the colour rather than moving the cursor.
        _ = screen.handle(.down, ctx: ctx)
        _ = screen.handle(.tab, ctx: ctx)
        XCTAssertTrue(screen.footerHints.contains { $0.label == "choose a colour" },
                      "tab should hand them back")
    }

    func testTheColourInHandIsWhatSpacePaintsWith() async throws {
        let screen = try XCTUnwrap(PixelEditorScreen(style: style, kind: .point,
                                                     code: 0x2a00, onSaved: {}))
        settle(screen)
        // Colour 1 is already under the cursor in the fixture, so painting with it would
        // change nothing. Take the next one.
        _ = screen.handle(.tab, ctx: ctx)
        _ = screen.handle(.down, ctx: ctx)
        _ = screen.handle(.tab, ctx: ctx)
        _ = screen.handle(.char(" "), ctx: ctx)
        XCTAssertTrue(screen.title.hasSuffix("·"), "the colour in hand should be painted")
    }

    // MARK: Profiles

    /// Every key the profile list advertises does something.
    func testTheProfileListAdvertisesNoKeyThatDoesNothing() async {
        let settings = ctx.settings
        let profiles = settings.settings.profiles
        let last = settings.settings.lastProfileID
        addTeardownBlock { @MainActor in
            settings.update { $0.profiles = profiles; $0.lastProfileID = last }
        }
        settings.update {
            $0.profiles = [BuildProfile(id: "a", name: "Alpha"),
                           BuildProfile(id: "b", name: "Beta")]
            $0.lastProfileID = "a"
        }

        let opening = ProfilesScreen()
        settle(opening)
        XCTAssertTrue(pushed(opening.handle(.enter, ctx: ctx)) is ProfileEditScreen,
                      "⏎ is advertised as \"open\" and must open something")

        // n asks for a name and opens what it made.
        let making = ProfilesScreen()
        settle(making)
        _ = making.handle(.char("n"), ctx: ctx)
        XCTAssertTrue(making.footerHints.contains { $0.label == "cancel" }, "n should ask")
        for c in "Gamma" { _ = making.handle(.char(c), ctx: ctx) }
        XCTAssertTrue(pushed(making.handle(.enter, ctx: ctx)) is ProfileEditScreen, "n")
        XCTAssertNotNil(settings.profiles.first { $0.name == "Gamma" })

        for key: Character in ["c", "r"] {
            let screen = ProfilesScreen()
            settle(screen)
            _ = screen.handle(.char(key), ctx: ctx)
            XCTAssertTrue(screen.footerHints.contains { $0.label == "cancel" },
                          "\(key) should ask for a name")
        }

        let deleting = ProfilesScreen()
        settle(deleting)
        _ = deleting.handle(.char("d"), ctx: ctx)
        XCTAssertTrue(deleting.footerHints.contains { $0.label == "keep it" },
                      "d should ask before deleting")

        let searching = ProfilesScreen()
        settle(searching)
        _ = searching.handle(.char("/"), ctx: ctx)
        XCTAssertTrue(searching.footerHints.contains { $0.label == "clear" }, "/")

        // m moves which profile the build screen opens on.
        let choosing = ProfilesScreen()
        settle(choosing)
        _ = choosing.handle(.down, ctx: ctx)
        _ = choosing.handle(.char("m"), ctx: ctx)
        XCTAssertNotEqual(settings.currentProfile.id, "a")
    }

    /// The same commands from a Cyrillic layout, where `d` arrives as `в`.
    func testTheProfileListReachesItsCommandsFromARussianLayout() async {
        let screen = ProfilesScreen()
        settle(screen)
        _ = screen.handle(.char("в"), ctx: ctx)
        // Either it asked, or it refused because there is only one profile; both are the
        // delete command answering.
        XCTAssertTrue(screen.footerHints.contains { $0.label == "keep it" }
                      || ctx.settings.profiles.count == 1)
    }

    func testTheDrawingScreenAsksForThePointer() async throws {
        let screen = try XCTUnwrap(PixelEditorScreen(style: style, kind: .point,
                                                     code: 0x2a00, onSaved: {}))
        XCTAssertTrue(screen.wantsMouse)
        // The lists do not: mouse reporting takes text selection away from the terminal.
        XCTAssertFalse(StyleListScreen().wantsMouse)
        XCTAssertFalse(TypeBrowserScreen(document: StyleDocument.load(style)).wantsMouse)
    }

    func testAClickLandsOnThePixelUnderIt() async throws {
        let screen = try XCTUnwrap(PixelEditorScreen(style: style, kind: .point,
                                                     code: 0x2a00, onSaved: {}))
        settle(screen)
        _ = screen.handle(.char("]"), ctx: ctx)
        // The canvas starts three columns in and one row down from the rect it was given.
        let event = MouseEvent(action: .press, x: 2 + 3 + 4 * 2, y: 2 + 1 + 1 + 3,
                               isPrimary: true)
        _ = screen.handle(.mouse(event), ctx: ctx)
        XCTAssertTrue(screen.title.hasSuffix("·"), "a click on the canvas should paint")
    }
}

private extension StyleListScreen {
    /// Renders once before its keys are pressed.
    func alsoSettled(_ test: ScreenKeysTests) -> StyleListScreen {
        test.settleForTests(self)
        return self
    }
}

extension ScreenKeysTests {
    func settleForTests(_ screen: Screen) { settle(screen) }
}
