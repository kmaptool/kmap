import XCTest

@testable import kmap

/// The pixel editor saves only what mkgmap compiles, and what it saves draws as it was
/// shown: a pattern's 4 colours, a clear that is never a pair's only colour, a night
/// that follows the day.
@MainActor
final class PixelEditorRulesTests: XCTestCase {
    private var ctx: AppContext!
    private var style: MapStyle!

    private static let source = """
        [_id]
        FID=6324
        ProductCode=1
        CodePage=1252
        [end]

        [_drawOrder]
        Type=0x16,1
        [end]

        [_polygon]
        Type=0x16
        Xpm="0 0 1 0"
        "a c #00AA00"
        [end]

        [_line]
        Type=0x02
        Xpm="0 0 4 0"
        "a c #FFFFFF"
        "b c #000000"
        "c c #888888"
        "d c #222222"
        LineWidth=3
        BorderWidth=1
        [end]

        [_point]
        Type=0x2f00
        DayXpm="2 2 2 1"
        "! c #FF0000"
        ". c none"
        "!."
        ".!"
        NightXpm="2 2 2 1"
        "! c #880000"
        ". c #000000"
        "!."
        ".!"
        [end]

        [_point]
        Type=0x2f01
        DayXpm="2 2 2 1"
        "! c #FF0000"
        ". c none"
        "!."
        ".!"
        NightXpm="3 3 2 2"
        "aa c #880000"
        "bb c none"
        "aabbaa"
        "bbaabb"
        "aabbaa"
        [end]
        """

    override func setUpWithError() throws {
        try MainActor.assumeIsolated {
            ctx = AppContext()
            let url = try TypLibrary.adopt(source: Self.source, named: "zz-pixel-rules-\(UUID().uuidString.prefix(8))")
            addTeardownBlock { try? TypLibrary.delete(url) }
            style = try XCTUnwrap(StyleCatalog.libraryStyle(at: url))
        }
    }

    private func editor(_ kind: MapElementKind, _ code: Int) throws -> PixelEditorScreen {
        let screen = try XCTUnwrap(PixelEditorScreen(style: style, kind: kind, code: code, onSaved: {}))
        draw(screen)
        return screen
    }

    @discardableResult
    private func draw(_ screen: PixelEditorScreen, width: Int = 80, height: Int = 24) -> String {
        let surface = Surface()
        surface.resize(width, height)
        surface.clear(ctx.theme.base)
        screen.render(into: surface, rect: Rect(x: 0, y: 2, w: width, h: height - 4), ctx: ctx)
        return stripControlSequences(surface.compose())
    }

    private func saved(_ kind: MapElementKind, _ code: Int) -> TypSection? {
        StyleDocument.load(style).source?.section(kind, code)
    }

    /// A pattern's colours are fixed at 4: a 5th stops mkgmap.
    func testAPatternTakesNoColourMore() async throws {
        let screen = try editor(.polygon, 0x16)
        screen.addColour("#123456")
        XCTAssertTrue(screen.messageIsError)
        XCTAssertEqual(screen.shown.palette.count, 4)
    }

    /// Both halves of a pair clear, or a single colour clear, stops mkgmap.
    func testAClearMkgmapRefusesIsRefused() async throws {
        let screen = try editor(.polygon, 0x16)
        XCTAssertNil(screen.shown.palette[1].colour, "the day background is clear")
        screen.changeColour(0, to: "none")
        XCTAssertTrue(screen.messageIsError)
        XCTAssertNotNil(screen.shown.palette[0].colour)
    }

    /// A line or polygon is 1 bit a pixel: the night pair is not a paint.
    func testThePatternsNightPairIsNotAPaint() async throws {
        let screen = try editor(.polygon, 0x16)
        XCTAssertFalse(screen.paint(x: 0, y: 0, with: 2))
        XCTAssertTrue(screen.paint(x: 0, y: 0, with: 1))
    }

    /// A pattern started from a cased line keeps its night fill, not its border.
    func testACasedLinesPatternKeepsItsNightFill() async throws {
        let screen = try editor(.line, 0x02)
        XCTAssertEqual(screen.shown.palette.map(\.colour), ["#FFFFFF", nil, "#888888", nil])
    }

    /// The day palette is the night's: a colour is added by day.
    func testAColourIsAddedByDayOnly() async throws {
        let screen = try editor(.point, 0x2f00)
        screen.toggleNight()
        screen.addColour("#0000FF")
        XCTAssertTrue(screen.messageIsError)
        screen.toggleNight()
        XCTAssertLessThan(screen.selected, screen.shown.palette.count)
    }

    /// Grown, a point's new ground is clear at night too, on screen and once saved.
    func testAGrownPointsNewGroundIsClearByNight() async throws {
        let screen = try editor(.point, 0x2f00)
        screen.toggleNight()
        screen.resize("3x3")
        let night = try XCTUnwrap(PixelEditorScreen.indices(of: screen.shown)[safe: 2]?[safe: 2])
        XCTAssertNil(screen.shown.palette[night].colour)
        screen.save()
        let after = try XCTUnwrap(saved(.point, 0x2f00)?.nightXpm)
        XCTAssertNil(after.palette[PixelEditorScreen.indices(of: after)[2][2]].colour)
        let day = try XCTUnwrap(saved(.point, 0x2f00)?.dayXpm)
        XCTAssertNil(day.palette[PixelEditorScreen.indices(of: day)[2][2]].colour)
    }

    /// A pattern taller than the terminal still shows its prompt and its palette.
    func testThePromptAndPaletteShowOnAnOrdinaryTerminal() async throws {
        let screen = try editor(.polygon, 0x16)
        _ = screen.handle(.char("c"), ctx: ctx)
        let drawn = draw(screen)
        XCTAssertTrue(drawn.contains(t("Colour %d becomes:", 1)), drawn)
        XCTAssertTrue(drawn.contains("#00AA00"), "the palette beside the canvas")
    }

    /// Enter is a paint key: on the leave question it leaves nothing.
    func testEnterDoesNotThrowUnsavedWorkAway() async throws {
        let screen = try editor(.polygon, 0x16)
        screen.paint(x: 0, y: 0, with: 1)
        _ = screen.handle(.esc, ctx: ctx)
        if case .pop = screen.handle(.enter, ctx: ctx) { XCTFail("left on Enter") }
        if case .pop = screen.handle(.char("y"), ctx: ctx) {} else { XCTFail("y leaves") }
    }

    /// A night drawn apart keeps its own size and key width when painted and saved.
    func testANightDrawnApartKeepsItsShape() async throws {
        let screen = try editor(.point, 0x2f01)
        screen.toggleNight()
        XCTAssertTrue(screen.paint(x: 2, y: 2, with: 1))
        XCTAssertEqual(screen.shown.width, 3)
        XCTAssertEqual(screen.shown.charsPerPixel, 2)
        screen.save()
        let night = try XCTUnwrap(saved(.point, 0x2f01)?.nightXpm)
        XCTAssertEqual([night.width, night.height, night.charsPerPixel], [3, 3, 2])
        XCTAssertEqual(night.rows, ["aabbaa", "bbaabb", "aabbbb"])
    }
}
