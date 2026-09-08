import XCTest
@testable import kmap

/// Drawing a TYP's own pictures on a screen made of characters.
///
/// A picture is painted as cell background with no glyph in it, so the assertions read
/// cells rather than `compose()`'s text.
final class PictureTests: XCTestCase {

    private func surface(_ w: Int = 60, _ h: Int = 30) -> Surface {
        let s = Surface()
        s.resize(w, h)
        s.clear(Style(fg: .default, bg: .default))
        return s
    }

    /// A picture built by hand, one character per pixel.
    private func block(_ rows: [String], palette: [(key: String, colour: String?)])
        -> XpmBlock {
        XpmBlock(width: rows.first?.count ?? 0, height: rows.count,
                 declaredColours: palette.count, charsPerPixel: 1,
                 palette: palette, rows: rows)
    }

    private let red = "#FF0000", blue = "#0000FF", black = "#000000", white = "#FFFFFF"

    // MARK: The stripes

    func testAPictureIsPaintedWithNoGlyphAnywhereInIt() {
        let picture = block(["rrbb", "brrb", "bbrr", "rbbr"],
                            palette: [("r", red), ("b", blue)])
        let s = surface()
        let rows = Widgets.picture(s, x: 2, y: 1, picture, background: .rgb(0, 0, 0))
        XCTAssertEqual(rows, 4)

        for y in 1..<5 {
            for x in 2..<(2 + 4 * Widgets.cellsPerPixel) {
                XCTAssertEqual(s.cell(x, y)?.ch, " ",
                               "a picture cell at \(x),\(y) is carrying a glyph; a glyph is"
                                   + " what put stripes through every icon")
            }
        }
    }

    func testACellIsExactlyItsOwnColour() {
        // Foreground and background both, so nothing depends on how the terminal draws
        // a character that is not there.
        let picture = block(["r"], palette: [("r", red)])
        let s = surface()
        Widgets.picture(s, x: 0, y: 0, picture, background: .rgb(0, 0, 0))
        XCTAssertEqual(s.cell(0, 0)?.style.fg, Color.hex(red))
        XCTAssertEqual(s.cell(0, 0)?.style.bg, Color.hex(red))
    }

    func testAPixelIsTwoCellsWideSoItComesOutSquare() {
        // A terminal cell is about twice as tall as it is wide; one cell per pixel would
        // draw a picture at half its width.
        let picture = block(["rb"], palette: [("r", red), ("b", blue)])
        let s = surface()
        Widgets.picture(s, x: 0, y: 0, picture, background: .rgb(0, 0, 0))
        XCTAssertEqual(s.cell(0, 0)?.style.bg, Color.hex(red))
        XCTAssertEqual(s.cell(1, 0)?.style.bg, Color.hex(red))
        XCTAssertEqual(s.cell(2, 0)?.style.bg, Color.hex(blue))
        XCTAssertEqual(s.cell(3, 0)?.style.bg, Color.hex(blue))
    }

    func testTransparentPixelsShowWhatTheySitOn() {
        // `none` in a TYP means the ground beneath shows through.
        let ground = Color.rgb(9, 9, 9)
        let picture = block(["nr"], palette: [("n", nil), ("r", red)])
        let s = surface()
        Widgets.picture(s, x: 0, y: 0, picture, background: ground)
        XCTAssertEqual(s.cell(0, 0)?.style.bg, ground)
        XCTAssertEqual(s.cell(2, 0)?.style.bg, Color.hex(red))
    }

    // MARK: Fitting it in

    func testAPictureThatFitsIsDrawnPixelForPixel() {
        let fit = Widgets.pictureFit(block(Array(repeating: "rr", count: 2),
                                           palette: [("r", red)]),
                                     maxColumns: 40, maxRows: 20)
        XCTAssertEqual(fit.scale, 1)
        XCTAssertEqual(fit.columns, 4)
        XCTAssertEqual(fit.rows, 2)
        XCTAssertFalse(fit.isReduced)
    }

    func testAPictureTallerThanItsBoxIsReducedByAWholeStep() {
        // Reduction goes by whole steps, so every cell stands for the same block of pixels.
        let picture = block(Array(repeating: String(repeating: "r", count: 20), count: 20),
                            palette: [("r", red)])
        let fit = Widgets.pictureFit(picture, maxColumns: 60, maxRows: 10)
        XCTAssertEqual(fit.scale, 2)
        XCTAssertEqual(fit.rows, 10)
        XCTAssertEqual(fit.columns, 20)
        XCTAssertTrue(fit.isReduced)
    }

    func testAPictureNeverDrawsOutsideTheBoxItWasGiven() {
        let picture = block(Array(repeating: String(repeating: "r", count: 32), count: 32),
                            palette: [("r", red)])
        for rows in 1...16 {
            for columns in stride(from: 4, through: 64, by: 6) {
                let fit = Widgets.pictureFit(picture, maxColumns: columns, maxRows: rows)
                XCTAssertLessThanOrEqual(fit.rows, rows)
                XCTAssertLessThanOrEqual(fit.columns, columns)
            }
        }
    }

    func testAReducedCellIsTheAverageOfWhatItStandsFor() {
        // Averaged rather than nearest-neighbour, which drops a one-pixel outline entirely.
        let picture = block(["wb", "bw"], palette: [("w", white), ("b", black)])
        let s = surface()
        Widgets.picture(s, x: 0, y: 0, picture, background: .rgb(0, 0, 0),
                        maxColumns: 2, maxRows: 1)
        XCTAssertEqual(s.cell(0, 0)?.style.bg, Color.rgb(127, 127, 127))
    }

    func testACellIsOnlyClearWhereNothingUnderItIsPainted() {
        // A clear surround stays clear; anything painted mixes with the ground in the
        // proportion it covers.
        let ground = Color.rgb(0, 0, 0)
        let clear = block(["nn", "nn"], palette: [("n", nil), ("r", red)])
        let sparse = block(["nn", "nr"], palette: [("n", nil), ("r", red)])
        let solid = block(["rr", "rr"], palette: [("r", red)])
        let s = surface()
        Widgets.picture(s, x: 0, y: 0, clear, background: ground, maxColumns: 2, maxRows: 1)
        Widgets.picture(s, x: 0, y: 2, sparse, background: ground, maxColumns: 2, maxRows: 1)
        Widgets.picture(s, x: 0, y: 4, solid, background: ground, maxColumns: 2, maxRows: 1)

        XCTAssertEqual(s.cell(0, 0)?.style.bg, ground, "nothing painted, nothing shown")
        XCTAssertEqual(s.cell(0, 2)?.style.bg, Color.rgb(63, 0, 0), "a quarter of the ink")
        XCTAssertEqual(s.cell(0, 4)?.style.bg, Color.hex(red))
    }

    // MARK: Lines

    func testASolidLineIsDrawnAtItsOwnThicknessWithItsCasing() {
        // Fill and casing are drawn at the widths given, not as one square of colour.
        let s = surface()
        let rows = Widgets.lineSample(s, rect: Rect(x: 0, y: 0, w: 6, h: 7),
                                      fill: red, casing: blue, width: 3, border: 1,
                                      background: .rgb(0, 0, 0))
        XCTAssertEqual(rows, 5)
        XCTAssertEqual(s.cell(0, 1)?.style.bg, Color.hex(blue), "casing above")
        XCTAssertEqual(s.cell(0, 2)?.style.bg, Color.hex(red))
        XCTAssertEqual(s.cell(0, 3)?.style.bg, Color.hex(red))
        XCTAssertEqual(s.cell(0, 4)?.style.bg, Color.hex(red))
        XCTAssertEqual(s.cell(0, 5)?.style.bg, Color.hex(blue), "casing below")
    }

    func testALineWithNoCasingIsJustItsOwnWidth() {
        let s = surface()
        let rows = Widgets.lineSample(s, rect: Rect(x: 0, y: 0, w: 6, h: 5),
                                      fill: red, casing: nil, width: 2, border: nil,
                                      background: .rgb(0, 0, 0))
        XCTAssertEqual(rows, 2)
        XCTAssertEqual(s.cell(0, 1)?.style.bg, Color.hex(red))
        XCTAssertEqual(s.cell(0, 2)?.style.bg, Color.hex(red))
    }

    func testALineTooThickForTheRoomKeepsItsCasingRatherThanItsMeasurements() {
        // Too little room: the casing is kept and the fill gives up rows, because a cased
        // line drawn without its casing reads as a different line.
        let s = surface()
        let rows = Widgets.lineSample(s, rect: Rect(x: 0, y: 0, w: 12, h: 3),
                                      fill: red, casing: blue, width: 4, border: 1,
                                      background: .rgb(0, 0, 0))
        XCTAssertEqual(rows, 3)
        XCTAssertEqual(s.cell(0, 0)?.style.bg, Color.hex(blue))
        XCTAssertEqual(s.cell(0, 1)?.style.bg, Color.hex(red))
        XCTAssertEqual(s.cell(0, 2)?.style.bg, Color.hex(blue))
    }

    func testALineThickerThanTheRoomIsClippedRatherThanDrawnOverTheRowBelow() {
        let s = surface()
        let rows = Widgets.lineSample(s, rect: Rect(x: 0, y: 2, w: 6, h: 2),
                                      fill: red, casing: blue, width: 9, border: 3,
                                      background: .rgb(0, 0, 0))
        XCTAssertLessThanOrEqual(rows, 2)
        XCTAssertNotEqual(s.cell(0, 4)?.style.bg, Color.hex(red))
    }

    // MARK: A real one

    func testTheFixtureIconComesOutAtItsOwnSize() throws {
        let source = TypSource.parse(TypFixture.source)
        let section = try XCTUnwrap(source.section(.point, TypFixture.iconCode))
        let icon = try XCTUnwrap(section.picture)
        XCTAssertEqual(icon.width, TypFixture.iconWidth)

        let fit = Widgets.pictureFit(icon, maxColumns: 80, maxRows: 40)
        XCTAssertEqual(fit.scale, 1)
        XCTAssertEqual(fit.columns, icon.width * Widgets.cellsPerPixel)
        XCTAssertEqual(fit.rows, icon.height)

        let s = surface(80, 40)
        let used = Widgets.picture(s, x: 0, y: 0, icon, background: .rgb(0, 0, 0))
        XCTAssertEqual(used, icon.height)
        for y in 0..<used {
            for x in 0..<fit.columns {
                XCTAssertEqual(s.cell(x, y)?.ch, " ")
            }
        }
    }

    // MARK: One row of it

    func testAPictureComesDownToOneRowOfColoursForAList() {
        // One row is one pixel of height: the picture is reduced across its width, not
        // cropped.
        let picture = block(["rrbb", "rrbb"], palette: [("r", red), ("b", blue)])
        let colours = Widgets.colourRow(picture, width: 4, on: .rgb(0, 0, 0))
        XCTAssertEqual(colours.count, 4)
        XCTAssertEqual(colours[0], Color.hex(red))
        XCTAssertEqual(colours[1], Color.hex(red))
        XCTAssertEqual(colours[2], Color.hex(blue))
        XCTAssertEqual(colours[3], Color.hex(blue))
    }

    func testTheWholeDrawingLandsInTwoCellsWhenThatIsAllThereIs() {
        // Two cells is one pixel: the whole drawing averaged into it.
        let picture = block(["ww", "bb"], palette: [("w", white), ("b", black)])
        let colours = Widgets.colourRow(picture, width: 2, on: .rgb(0, 0, 0))
        XCTAssertEqual(colours, [Color.rgb(127, 127, 127), Color.rgb(127, 127, 127)])
    }

    func testARowIsPaintedInTheBottomHalfOfItsCellsSoEntriesKeepTheirEnds() {
        // Painting the lower half leaves a gap above, so stacked rows keep their ends
        // without costing a blank line.
        let ground = Color.rgb(9, 9, 9)
        let s = surface()
        Widgets.halfRow(s, x: 1, y: 1, colours: [Color.hex(red), nil, Color.hex(blue)],
                        background: ground)
        XCTAssertEqual(s.cell(1, 1)?.ch, Glyph.lowerHalf)
        XCTAssertEqual(s.cell(1, 1)?.style.fg, Color.hex(red))
        XCTAssertEqual(s.cell(1, 1)?.style.bg, ground, "the gap is the row's own ground")
        XCTAssertNotEqual(s.cell(2, 1)?.ch, Glyph.lowerHalf, "nothing painted, nothing drawn")
        XCTAssertEqual(s.cell(3, 1)?.style.fg, Color.hex(blue))
    }
}
