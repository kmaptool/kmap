import XCTest
@testable import kmap

/// Day and night, and the label the receiver prints.
///
/// Day and night are how the format stores a section; the arrangement differs by element
/// and by how many colours the section carries.
final class DayNightTests: XCTestCase {

    private func section(_ text: String, _ kind: MapElementKind,
                         _ code: Int) throws -> TypSection {
        try XCTUnwrap(TypSource.parse(text).section(kind, code))
    }

    // MARK: How the colours pair up

    func testTwoSolidColoursAreDayAndNight() throws {
        let slots = try section("""
            [_polygon]
            Type=0x16
            Xpm="0 0 2 0"
            "a c #A0D070"
            "b c #204020"
            [end]
            """, .polygon, 0x16).colourSlots

        XCTAssertEqual(slots.day.map(\.colour), ["#A0D070"])
        XCTAssertEqual(slots.night.map(\.colour), ["#204020"])
    }

    /// Four colours on a cased line are day fill, day casing, night fill, night casing.
    func testFourColoursOnACasedLinePairFillWithFillAndCasingWithCasing() throws {
        let slots = try section("""
            [_line]
            Type=0x07
            Xpm="0 0 4 0"
            "a c #D0D4D0"
            "b c #404040"
            "c c #B0B4B0"
            "d c #686868"
            LineWidth=1
            BorderWidth=1
            [end]
            """, .line, 0x07).colourSlots

        XCTAssertEqual(slots.day.map(\.role), ["Fill", "Casing"])
        XCTAssertEqual(slots.day.map(\.colour), ["#D0D4D0", "#404040"])
        XCTAssertEqual(slots.night.map(\.colour), ["#B0B4B0", "#686868"])
    }

    /// A pattern's four are day ink, day background, night ink, night background.
    func testAPatternPairsInkWithInkAndBackgroundWithBackground() throws {
        let slots = try section("""
            [_line]
            Type=0x23
            Xpm="4 2 4 1"
            "! c #789400"
            ". c none"
            "3 c #445500"
            "4 c none"
            "!..!"
            "..!."
            [end]
            """, .line, 0x23).colourSlots

        XCTAssertEqual(slots.day.map(\.role), ["Ink", "Background"])
        XCTAssertEqual(slots.day.map(\.colour), ["#789400", nil])
        XCTAssertEqual(slots.night.map(\.colour), ["#445500", nil])
    }

    /// Two colours on a cased line are both the day pair; night is left unsaid rather than
    /// repeated, since absence and a repeated pair are different facts about the file.
    func testACasedLineWithOnlyTwoColoursSaysNothingAboutNight() throws {
        let slots = try section("""
            [_line]
            Type=0x07
            Xpm="0 0 2 0"
            "a c #D0D4D0"
            "b c #404040"
            LineWidth=1
            BorderWidth=1
            [end]
            """, .line, 0x07).colourSlots

        XCTAssertEqual(slots.day.map(\.colour), ["#D0D4D0", "#404040"])
        XCTAssertEqual(slots.night, [])
    }

    /// A point keeps its night picture in a second block, so each slot names the block it
    /// belongs to.
    func testAPointsNightColoursComeFromItsOwnBlock() throws {
        let slots = try section("""
            [_point]
            Type=0x2a00
            DayXpm="1 1 1 1"
            "a c #FFFFFF"
            "a"
            NightXpm="1 1 1 1"
            "a c #202020"
            "a"
            [end]
            """, .point, 0x2a00).colourSlots

        XCTAssertEqual(slots.day.map(\.colour), ["#FFFFFF"])
        XCTAssertEqual(slots.day.map(\.tag), ["DayXpm"])
        XCTAssertEqual(slots.night.map(\.colour), ["#202020"])
        XCTAssertEqual(slots.night.map(\.tag), ["NightXpm"])
    }

    func testAPointWithNoNightBlockSaysNothingAboutNight() throws {
        let slots = try section("""
            [_point]
            Type=0x2a00
            DayXpm="1 1 1 1"
            "a c #FFFFFF"
            "a"
            [end]
            """, .point, 0x2a00).colourSlots
        XCTAssertEqual(slots.night, [])
    }

    // MARK: Writing to the right one

    func testANightColourIsWrittenIntoTheNightBlock() throws {
        let text = """
            [_point]
            Type=0x2a00
            DayXpm="1 1 1 1"
            "a c #FFFFFF"
            "a"
            NightXpm="1 1 1 1"
            "a c #202020"
            "a"
            [end]
            """
        let source = TypSource.parse(text)
        let edited = try TypEdit.setColour(in: source, kind: .point, code: 0x2a00,
                                           colourIndex: 0, to: "#101010", tag: "NightXpm")
        let after = try XCTUnwrap(TypSource.parse(edited).section(.point, 0x2a00))

        XCTAssertEqual(after.dayXpm?.colours, ["#FFFFFF"], "the day colour must not move")
        XCTAssertEqual(after.nightXpm?.colours, ["#101010"])
    }

    // MARK: Starting a night version

    func testANightPictureStartsAsACopyOfTheDayOne() throws {
        let source = TypSource.parse("""
            [_point]
            Type=0x2a00
            DayXpm="2 2 2 1"
            "a c #FFFFFF"
            "b c none"
            "ab"
            "ba"
            String=0x00,Something
            [end]
            """)
        let edited = try TypEdit.addNightPicture(in: source, code: 0x2a00)
        let after = try XCTUnwrap(TypSource.parse(edited).section(.point, 0x2a00))

        XCTAssertEqual(after.nightXpm?.rows, after.dayXpm?.rows, "the same drawing")
        XCTAssertEqual(after.nightXpm?.colours, after.dayXpm?.colours, "and its colours, to start")
        XCTAssertEqual(after.englishLabel, "Something")
    }

    func testAPointThatAlreadyHasOneIsRefused() {
        let source = TypSource.parse("""
            [_point]
            Type=0x2a00
            DayXpm="1 1 1 1"
            "a c #FFFFFF"
            "a"
            NightXpm="1 1 1 1"
            "a c #202020"
            "a"
            [end]
            """)
        XCTAssertThrowsError(try TypEdit.addNightPicture(in: source, code: 0x2a00))
    }

    // MARK: Saying something about night where nothing was said

    func testATwoColourPatternGrowsToFourSoNightCanBeSaid() throws {
        let source = TypSource.parse("""
            [_polygon]
            Type=0x0c
            ; a comment that must survive
            Xpm="4 2 2 1"
            "! c #F0D8A8"
            ". c #C8CCC8"
            "!.!."
            ".!.!"
            String=0x19,Промзона
            [end]
            """)
        XCTAssertTrue(try section(source.text, .polygon, 0x0c).colourSlots.night.isEmpty)

        let edited = try TypEdit.addNightColours(in: source, kind: .polygon, code: 0x0c)
        let after = try section(edited, .polygon, 0x0c)

        // The night pair starts as the day pair; the edit makes room, it does not restyle.
        XCTAssertEqual(after.colourSlots.day.map(\.colour), ["#F0D8A8", "#C8CCC8"])
        XCTAssertEqual(after.colourSlots.night.map(\.colour), ["#F0D8A8", "#C8CCC8"])

        // The rows only ever name the first two keys, so the picture is unchanged.
        XCTAssertEqual(after.picture?.rows, ["!.!.", ".!.!"])
        XCTAssertEqual(after.picture?.pixels(), source.section(.polygon, 0x0c)?
            .picture?.pixels())
        XCTAssertEqual(after.russianLabel, "Промзона")
        XCTAssertTrue(after.comments.contains { $0.contains("must survive") })
    }

    func testTheNewNightColourIsThenEditableWithoutDisturbingDay() throws {
        let source = TypSource.parse("""
            [_line]
            Type=0x07
            Xpm="0 0 2 0"
            "a c #D0D4D0"
            "b c #404040"
            LineWidth=1
            BorderWidth=1
            [end]
            """)
        let grown = TypSource.parse(try TypEdit.addNightColours(in: source, kind: .line,
                                                                code: 0x07))
        let nightFill = try XCTUnwrap(grown.section(.line, 0x07)?.colourSlots.night.first)

        let edited = try TypEdit.setColour(in: grown, kind: .line, code: 0x07,
                                           colourIndex: nightFill.index, to: "#101820",
                                           tag: nightFill.tag)
        let after = try section(edited, .line, 0x07)

        XCTAssertEqual(after.colourSlots.day.map(\.colour), ["#D0D4D0", "#404040"],
                       "the day pair must not move")
        XCTAssertEqual(after.colourSlots.night.map(\.colour), ["#101820", "#404040"])
    }

    func testAnElementThatAlreadySaysSomethingAboutNightIsRefused() {
        let source = TypSource.parse("""
            [_polygon]
            Type=0x16
            Xpm="0 0 2 0"
            "a c #A0D070"
            "b c #204020"
            [end]
            """)
        // Two solid colours are already day and night; there is nothing to add.
        XCTAssertThrowsError(try TypEdit.addNightColours(in: source, kind: .polygon,
                                                         code: 0x16))
    }

    // MARK: The label

    private let labelled = """
        [_line]
        Type=0x20
        ; a comment that must survive every one of these
        Xpm="0 0 1 0"
        "a c #A89028"
        LineWidth=1
        FontStyle=SmallFont
        DayCustomColor=#685820
        [end]
        """

    func testTheFontSizeIsReplacedInPlace() throws {
        let edited = try TypEdit.setFontStyle(in: TypSource.parse(labelled), kind: .line,
                                              code: 0x20, to: "LargeFont")
        let after = try XCTUnwrap(TypSource.parse(edited).section(.line, 0x20))
        XCTAssertEqual(after.fontStyle, "LargeFont")
        XCTAssertTrue(after.comments.contains { $0.contains("must survive") })
    }

    /// An absent tag leaves the size to the receiver, which is not the same as naming the
    /// default.
    func testTheFontSizeCanBeTakenOutAltogether() throws {
        let edited = try TypEdit.setFontStyle(in: TypSource.parse(labelled), kind: .line,
                                              code: 0x20, to: nil)
        XCTAssertNil(TypSource.parse(edited).section(.line, 0x20)?.fontStyle)
        XCTAssertFalse(edited.contains("FontStyle"), edited)
    }

    func testAFontSizeIsAddedWhereThereWasNone() throws {
        let plain = "[_line]\nType=0x20\nXpm=\"0 0 1 0\"\n\"a c #A89028\"\n[end]"
        let edited = try TypEdit.setFontStyle(in: TypSource.parse(plain), kind: .line,
                                              code: 0x20, to: "NoLabel")
        XCTAssertEqual(TypSource.parse(edited).section(.line, 0x20)?.fontStyle, "NoLabel")
        XCTAssertEqual(TypSource.parse(edited).section(.line, 0x20)?.colours, ["#A89028"])
    }

    /// The label's colour is not the element's: without the tag the receiver colours the
    /// label, which differs from setting it to the line's colour.
    func testTheLabelColourIsSetAndRemovedOnItsOwn() throws {
        let source = TypSource.parse(labelled)
        XCTAssertEqual(source.section(.line, 0x20)?.dayLabelColour, "#685820")

        let night = try TypEdit.setLabelColour(in: source, kind: .line, code: 0x20,
                                               night: true, to: "#FFD080")
        let withNight = try XCTUnwrap(TypSource.parse(night).section(.line, 0x20))
        XCTAssertEqual(withNight.dayLabelColour, "#685820", "the day one must not move")
        XCTAssertEqual(withNight.nightLabelColour, "#FFD080")
        XCTAssertEqual(withNight.colours, ["#A89028"], "nor the colour the line is drawn in")

        let removed = try TypEdit.setLabelColour(in: TypSource.parse(night), kind: .line,
                                                 code: 0x20, night: false, to: nil)
        XCTAssertNil(TypSource.parse(removed).section(.line, 0x20)?.dayLabelColour)
        XCTAssertEqual(TypSource.parse(removed).section(.line, 0x20)?.nightLabelColour,
                       "#FFD080")
    }

    /// A tag holding something that is not a colour is refused by the compiler.
    func testALabelColourThatIsNotAColourIsRefused() {
        let source = TypSource.parse(labelled)
        XCTAssertThrowsError(try TypEdit.setLabelColour(in: source, kind: .line, code: 0x20,
                                                        night: false, to: "reddish"))
        XCTAssertThrowsError(try TypEdit.setLabelColour(in: source, kind: .line, code: 0x20,
                                                        night: false, to: "none"))
    }
}
