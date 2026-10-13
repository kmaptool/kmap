import XCTest

@testable import kmap

/// Reading an mkgmap TYP *source* file. Parsing is half a round trip, so the file must
/// reassemble byte for byte.
final class TypSourceTests: XCTestCase {
    // MARK: Changing the grid

    /// Growing pads with transparency, adding a transparent palette entry where there is
    /// none, rather than with the first colour in the palette.
    func testGrowingAPictureFillsTheNewGroundWithNothing() throws {
        let source = TypSource.parse(
            """
            [_point]
            Type=0x2a00
            DayXpm="2 2 1 1"
            "a c #FF0000"
            "aa"
            "aa"
            [end]
            """
        )
        let picture = try XCTUnwrap(source.section(.point, 0x2a00)?.picture)
        let grown = picture.resized(width: 4, height: 3)

        XCTAssertEqual(grown.width, 4)
        XCTAssertEqual(grown.height, 3)
        let grid = try XCTUnwrap(grown.pixels())
        XCTAssertEqual(grid[0], ["#FF0000", "#FF0000", nil, nil])
        XCTAssertEqual(grid[2], [nil, nil, nil, nil], "the new row is clear")
    }

    /// A picture keyed 2 characters a pixel, with no clear colour yet, grows too.
    func testATwoCharacterPictureWithoutAClearColourGrows() throws {
        let picture = XpmBlock(
            width: 1,
            height: 1,
            declaredColours: 1,
            charsPerPixel: 2,
            palette: [(key: "aa", colour: "#FF0000")],
            rows: ["aa"]
        )
        let grown = picture.resized(width: 2, height: 1)
        XCTAssertEqual(grown.width, 2)
        XCTAssertEqual(try XCTUnwrap(grown.pixels())[0], ["#FF0000", nil])
    }

    /// 3 characters a pixel get a clear key of 3, or every row after it would be misread.
    func testAThreeCharacterPictureGrowsWithAKeyAsWide() throws {
        let picture = XpmBlock(
            width: 1,
            height: 1,
            declaredColours: 1,
            charsPerPixel: 3,
            palette: [(key: "aaa", colour: "#FF0000")],
            rows: ["aaa"]
        )
        let grown = picture.resized(width: 2, height: 1)
        XCTAssertEqual(grown.palette.last?.key.count, 3)
        XCTAssertEqual(try XCTUnwrap(grown.pixels())[0], ["#FF0000", nil])
    }

    func testAKeyIsTheSlotInTheAlphabetsDigits() {
        let n = XpmBlock.keyAlphabet.count
        XCTAssertEqual(XpmBlock.key(0, width: 1), "!")
        XCTAssertEqual(XpmBlock.key(n + 1, width: 2), "##")
        XCTAssertEqual(XpmBlock.key(1, width: 3), "!!#")
    }

    /// Cropping is anchored at the top-left.
    func testShrinkingKeepsTheTopLeft() throws {
        let source = TypSource.parse(
            """
            [_point]
            Type=0x2a00
            DayXpm="3 3 2 1"
            "a c #FF0000"
            "b c #0000FF"
            "aab"
            "aab"
            "bbb"
            [end]
            """
        )
        let picture = try XCTUnwrap(source.section(.point, 0x2a00)?.picture)
        let cropped = picture.resized(width: 2, height: 2)

        XCTAssertEqual(cropped.pixels(), [["#FF0000", "#FF0000"], ["#FF0000", "#FF0000"]])
    }

    /// A resized picture must still write back into a TYP and read the same.
    func testAResizedPictureSurvivesBeingWrittenOut() throws {
        let source = TypSource.parse(
            """
            [_point]
            Type=0x2a00
            DayXpm="2 2 1 1"
            "a c #FF0000"
            "aa"
            "aa"
            String=0x00,Something
            [end]
            """
        )
        let picture = try XCTUnwrap(source.section(.point, 0x2a00)?.picture)
        let edited = try TypEdit.setPicture(
            in: source,
            kind: .point,
            code: 0x2a00,
            to: picture.resized(width: 5, height: 5)
        )
        let after = try XCTUnwrap(TypSource.parse(edited).section(.point, 0x2a00))

        XCTAssertEqual(after.picture?.width, 5)
        XCTAssertEqual(after.picture?.rows.count, 5)
        XCTAssertEqual(after.picture?.palette.count, after.picture?.declaredColours)
        XCTAssertEqual(after.englishLabel, "Something")
    }

    // MARK: Draw order

    /// A polygon absent from `[_drawOrder]` is never drawn, and is reported as such.
    func testAPolygonMissingFromTheDrawOrderIsReported() {
        let source = TypSource.parse(
            """
            [_drawOrder]
            Type=0x016,2
            [end]
            [_polygon]
            Type=0x16
            Xpm="0 0 1 0"
            "a c #A0D070"
            [end]
            [_polygon]
            Type=0x50
            Xpm="0 0 1 0"
            "a c #204020"
            [end]
            """
        )
        XCTAssertEqual(source.drawOrder.map(\.code), [0x16])
        XCTAssertEqual(source.polygonsMissingFromDrawOrder, [0x50])
    }

    // MARK: A pattern with nothing in it

    /// A pattern whose every pixel is transparent is reported as blank, though the element
    /// still names a colour. The pattern itself round-trips byte for byte.
    func testAPatternWithNothingVisibleInItSaysSo() throws {
        let source = TypSource.parse(
            """
            [_id]
            FID=1
            ProductCode=1
            CodePage=1252
            [end]

            [_line]
            Type=0x01
            Xpm="4 2 2 1"
            "! c #809BC0"
            "# c none"
            "####"
            "####"
            [end]

            [_line]
            Type=0x02
            Xpm="4 2 2 1"
            "! c #809BC0"
            "# c none"
            "!!##"
            "!!##"
            [end]
            """
        )

        let blank = try XCTUnwrap(source.section(.line, 0x01))
        XCTAssertNotNil(blank.picture, "the pattern is there; it is its pixels that are not")
        XCTAssertTrue(blank.patternIsBlank)
        XCTAssertEqual(
            blank.colours.first ?? nil,
            "#809BC0",
            "the one colour it names is what a device can draw it in"
        )

        let dashed = try XCTUnwrap(source.section(.line, 0x02))
        XCTAssertFalse(dashed.patternIsBlank)
    }

    func testASectionWithNoPictureAtAllIsNotCalledBlank() {
        // A solid line has no pattern at all, which is not the same as a blank one.
        let source = TypSource.parse(
            """
            [_id]
            FID=1
            ProductCode=1
            CodePage=1252
            [end]

            [_line]
            Type=0x03
            Xpm="0 0 2 0"
            "! c #FF0000"
            "# c #000000"
            LineWidth=3
            [end]
            """
        )
        XCTAssertEqual(source.section(.line, 0x03)?.patternIsBlank, false)
    }

    // MARK: Code pages kmap cannot read, and bytes a page leaves undefined

    /// A palette with every 1-character key used crops, which pads nothing, and stays as
    /// it is when asked to grow: no key is left for the clear ground.
    func testAFullPaletteCropsButCannotGrow() {
        let keys = XpmBlock.keyAlphabet.map(String.init)
        let picture = XpmBlock(
            width: 2,
            height: 1,
            declaredColours: keys.count,
            charsPerPixel: 1,
            palette: keys.enumerated().map { (key: $0.element, colour: String(format: "#%06X", $0.offset)) },
            rows: [keys[0] + keys[1]]
        )
        let cropped = picture.resized(width: 1, height: 1)
        XCTAssertEqual(cropped.width, 1)
        XCTAssertEqual(cropped.palette.count, keys.count, "no clear entry added for a crop")
        XCTAssertEqual(picture.resized(width: 3, height: 1).width, 2)
    }
}
