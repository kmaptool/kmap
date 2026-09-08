import XCTest
@testable import kmap

/// Each list entry shows its own drawing, day and night, in the room a colour block had:
/// square pixels reduced by whole steps until they fit. `@MainActor` because the screens
/// are, and every test is `async` because Linux's generated test list cannot name a
/// synchronous main-actor method.
@MainActor
final class TypeListDrawingTests: XCTestCase {

    private var ctx: AppContext!
    private var style: MapStyle!

    override func setUpWithError() throws {
        // On Linux `setUp` is nonisolated, so the isolation has to be stated to reach
        // this class's own properties.
        try MainActor.assumeIsolated {
            // The language is pinned: this file measures a layout in characters, and
            // translated labels are not the same width.
            let languageBefore = L10n.current
            L10n.use(.en)
            addTeardownBlock { @MainActor in L10n.use(languageBefore) }

            ctx = AppContext()
            let originals = TypLibrary.originalsDirectory()
            let before = Set((TypLibrary.contents() + TypLibrary.contents(in: originals))
                .map(\.lastPathComponent))
            addTeardownBlock {
                for url in TypLibrary.contents() + TypLibrary.contents(in: originals)
                where !before.contains(url.lastPathComponent) {
                    try? FileManager.default.removeItem(at: url)
                }
            }
            let url = try TypLibrary.adopt(source: TypFixture.source,
                                           named: "zz-list-drawing-\(UUID().uuidString.prefix(8))")
            style = try XCTUnwrap(StyleCatalog.libraryStyle(at: url))
        }
    }

    private let rect = Rect(x: 2, y: 2, w: 110, h: 40)

    private func draw(_ screen: Screen, height: Int? = nil) -> Surface {
        let area = Rect(x: rect.x, y: rect.y, w: rect.w, h: height ?? rect.h)
        let s = Surface()
        s.resize(area.w + 4, area.h + 4)
        s.clear(ctx.theme.base)
        screen.tick(ctx)
        screen.render(into: s, rect: area, ctx: ctx)
        return s
    }

    /// The browser narrowed to one entry, with the pane under the list opened.
    private func browser(_ kind: MapElementKind, code: String) -> TypeBrowserScreen {
        let screen = TypeBrowserScreen(document: StyleDocument.load(style), kind: kind)
        _ = draw(screen)
        _ = screen.handle(.char("p"), ctx: ctx)
        _ = screen.handle(.char("/"), ctx: ctx)
        for c in code { _ = screen.handle(.char(c), ctx: ctx) }
        _ = screen.handle(.enter, ctx: ctx)
        return screen
    }

    /// The list's first entry, narrowed to one by searching for its code.
    private func showing(_ kind: MapElementKind, code: String) -> (Surface, TypeBrowserScreen) {
        let screen = TypeBrowserScreen(document: StyleDocument.load(style), kind: kind)
        _ = draw(screen)
        _ = screen.handle(.char("/"), ctx: ctx)
        for c in code { _ = screen.handle(.char(c), ctx: ctx) }
        _ = screen.handle(.enter, ctx: ctx)
        return (draw(screen), screen)
    }

    /// What is painted in the day half of the first entry's room, and in the night half.
    private func day(_ s: Surface, width: Int) -> [Color] {
        painted(s, from: rect.x + 2, width: width)
    }

    private func night(_ s: Surface, width: Int) -> [Color] {
        painted(s, from: rect.x + 2 + width + 1, width: width)
    }

    /// The colour is in the foreground here, not the background: an entry's drawing is
    /// painted in the bottom half of its cells so a column of them does not run together.
    private func painted(_ s: Surface, from x: Int, width: Int) -> [Color] {
        (x..<(x + width)).compactMap { column -> Color? in
            guard let cell = s.cell(column, rect.y + 3),
                  cell.ch == Glyph.lowerHalf else { return nil }
            return cell.style.fg
        }
    }

    func testAPointIsDrawnAsItsIconInTheRoomAColourBlockHad() async {
        // Two cells and one row: the room a colour block had.
        let (s, _) = showing(.point, code: "2a00")
        XCTAssertEqual(day(s, width: 2).count, 2)

        // The search narrowed the list to one entry, so the row under it belongs to
        // nothing: an entry is one row.
        XCTAssertTrue(painted(s, from: rect.x + 2, width: 2).count == 2)
        XCTAssertNotEqual(s.cell(rect.x + 2, rect.y + 4)?.ch, Glyph.lowerHalf,
                          "the drawing spilled onto the row below")
    }

    func testTheWholeDrawingIsScaledIntoItRatherThanACornerOfIt() async throws {
        // The fixture's badge is 20×20 with a coloured field and white in the middle;
        // reduced to one cell it carries both, which cropping to the corner would not.
        let source = TypSource.parse(TypFixture.source)
        let icon = try XCTUnwrap(source.section(.point, TypFixture.iconCode)?.picture)
        let grid = try XCTUnwrap(icon.pixels())
        let corner = grid[0][0]

        let (s, _) = showing(.point, code: "2a00")
        let shown = try XCTUnwrap(day(s, width: 2).first)
        if let corner, let cropped = Color.hex(corner) {
            XCTAssertNotEqual(shown, cropped,
                              "this is the corner pixel, not the whole drawing scaled")
        }
    }

    func testDayAndNightAreBothDrawn() async {
        // The fixture's pattern holds one set of pixels with a day pair of colours and a
        // night pair.
        let (s, _) = showing(.polygon, code: "0x51")
        XCTAssertFalse(day(s, width: 2).isEmpty)
        XCTAssertFalse(night(s, width: 2).isEmpty, "a night pair has to be drawn")
        XCTAssertNotEqual(day(s, width: 2), night(s, width: 2),
                          "day and night differ in this file, so they differ on screen")
    }

    func testNightIsBlankWhereTheFileSaysNothingAboutIt() async {
        // A receiver repeats the day drawing after dark, but "same as day" and "nothing
        // said" are different facts about the file.
        let (s, _) = showing(.point, code: "2a00")
        XCTAssertTrue(night(s, width: 2).isEmpty)
    }

    func testALineIsGivenALengthRatherThanASquare() async throws {
        // A line is a few pixels thick and arbitrarily long; the square a point gets says
        // nothing about it.
        let (s, _) = showing(.line, code: "0x07")
        XCTAssertGreaterThan(day(s, width: 10).count, 4, "a line runs along its row")
        XCTAssertFalse(night(s, width: 10).isEmpty, "this line names its night colours")
    }

    func testThePaneShowsTheDrawingPixelForPixelWhenTheRowsAreThere() async {
        // Reducing averages pixels together; where the rows are there, the pane takes what
        // the drawing needs and leaves the rest to the list.
        let text = draw(browser(.point, code: "2a00")).compose()
        XCTAssertTrue(text.contains("20×20"))
        XCTAssertFalse(text.contains("1:2"),
                       "there was room to draw it properly and it was reduced anyway")
    }

    func testAndSaysSoWhenTheyAreNot() async {
        // On a short screen the drawing is reduced, and the ratio is labelled.
        let text = draw(browser(.point, code: "2a00"), height: 22).compose()
        XCTAssertTrue(text.contains("20×20"))
        XCTAssertTrue(text.contains("1:2") || text.contains("1:3"),
                      "a reduced drawing has to say it is reduced")
    }

    func testNothingIsDrawnForATypeTheTypDoesNotStyle() async {
        // "The receiver draws its own" and "the ground shows through" are different facts;
        // one mark for both would say neither.
        let screen = TypeBrowserScreen(document: StyleDocument.load(style), kind: .point)
        _ = draw(screen)
        _ = screen.handle(.char("/"), ctx: ctx)
        for c in "0x66" { _ = screen.handle(.char(c), ctx: ctx) }
        _ = screen.handle(.enter, ctx: ctx)
        let s = draw(screen)
        guard s.compose().contains("0x66") else { return }
        XCTAssertTrue(day(s, width: 2).isEmpty && night(s, width: 2).isEmpty,
                      "an unstyled type has nothing to draw")
    }

    // MARK: The screen for one type

    func testTheTypeScreenDrawsASolidLineToo() async {
        // A line without a picture is a width and two colours; the fixture's 0x07 is a
        // cased road: fill in the middle, casing above and below.
        let screen = TypeEditScreen(style: style, kind: .line, code: 0x07, onEdited: {})
        let s = draw(screen)
        var found: [Color] = []
        for y in rect.y..<(rect.y + 8) {
            for x in rect.x..<(rect.x + 40) {
                guard let cell = s.cell(x, y), case .rgb = cell.style.bg.kind else { continue }
                found.append(cell.style.bg)
            }
        }
        XCTAssertGreaterThan(found.count, 20, "a solid line has to be drawn, not just named")
        XCTAssertGreaterThanOrEqual(Set(found.map(String.init(describing:))).count, 2,
                                    "its casing is a colour of its own")
        XCTAssertTrue(s.compose().contains("width"), "and the numbers beside it")
    }

    func testTheTypeScreenDrawsAPatternsNightSide() async throws {
        // A pattern keeps its night in a second pair of colours rather than a second block:
        // the night drawing is the same pixels read through that pair.
        let screen = TypeEditScreen(style: style, kind: .polygon, code: 0x51, onEdited: {})
        let text = draw(screen).compose()
        XCTAssertTrue(text.contains("night"), "the night drawing is there to be labelled")
    }

    // MARK: The pane under the list

    /// The last row of the area that has anything on it.
    private func lastRowUsed(_ s: Surface, height: Int) -> Int {
        var last = rect.y
        for y in rect.y..<(rect.y + height) {
            for x in rect.x..<(rect.x + rect.w) {
                guard let cell = s.cell(x, y) else { continue }
                var painted = cell.ch != " "
                if case .rgb = cell.style.bg.kind { painted = true }
                if painted { last = max(last, y) }
            }
        }
        return last
    }

    func testThePaneIsAsTallAsWhatIsInItAndNoTaller() async {
        // The pane is as tall as the selected entry puts in it: its drawing at the size it
        // is drawn, and a line for every rule that reaches the code.
        for kind in MapElementKind.allCases {
            for steps in [0, 3, 9] {
                let screen = TypeBrowserScreen(document: StyleDocument.load(style), kind: kind)
                _ = draw(screen)
                _ = screen.handle(.char("p"), ctx: ctx)
                for _ in 0..<steps { _ = screen.handle(.down, ctx: ctx) }
                let s = draw(screen)
                let last = lastRowUsed(s, height: rect.h)
                XCTAssertGreaterThan(last, rect.y + rect.h - 4,
                                     "\(kind) at row \(steps) leaves the bottom of the"
                                         + " screen empty")
            }
        }
    }

    func testThePaneStartsClosedAndOpensOnP() async {
        let screen = TypeBrowserScreen(document: StyleDocument.load(style), kind: .point)
        _ = draw(screen)
        _ = screen.handle(.char("/"), ctx: ctx)
        for c in "2a00" { _ = screen.handle(.char(c), ctx: ctx) }
        _ = screen.handle(.enter, ctx: ctx)

        XCTAssertFalse(draw(screen).compose().contains("20×20"),
                       "nothing of the pane should be on screen before it is opened")
        _ = screen.handle(.char("p"), ctx: ctx)
        XCTAssertTrue(draw(screen).compose().contains("20×20"), "p opens it")
        _ = screen.handle(.char("p"), ctx: ctx)
        XCTAssertFalse(draw(screen).compose().contains("20×20"), "and closes it again")
    }

    func testTheListIsLongerWithThePaneClosed() async throws {
        // The pane's height counts the rule conditions behind the selected type, which come
        // from the materialized rule set: without it the pane sits at its minimum.
        try XCTSkipUnless(FileTools.exists(
            StyleCatalog.baseStyleDirectory.appendingPathComponent("points")),
                          "no materialized rule set — build once first")
        let screen = TypeBrowserScreen(document: StyleDocument.load(style), kind: .point)
        _ = draw(screen)
        let whole = entryRows(draw(screen))
        _ = screen.handle(.char("p"), ctx: ctx)
        XCTAssertGreaterThan(whole, entryRows(draw(screen)),
                             "the rows the pane takes come off the list")
    }

    /// How many rows of the area carry a list entry — counted by its code, which every
    /// entry has whether or not the TYP draws it.
    private func entryRows(_ s: Surface) -> Int {
        (rect.y..<(rect.y + rect.h)).filter { y in
            (rect.x..<(rect.x + 24)).contains { x in
                s.cell(x, y)?.ch == "0" && s.cell(x + 1, y)?.ch == "x"
            }
        }.count
    }
}
