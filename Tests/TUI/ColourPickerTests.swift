import XCTest
@testable import kmap

/// Covers choosing a colour without typing its hex, and reaching a command whatever
/// alphabet the keyboard is in.
final class ColourPickerTests: XCTestCase {

    // MARK: The spread

    func testEverySwatchIsARealColour() {
        for row in 0...ColourPicker.levels {
            for column in 0..<24 {
                let colour = ColourPicker.colour(row: row, column: column, hues: 24)
                XCTAssertNotNil(Color.hex(colour), "row \(row) column \(column): \(colour)")
            }
        }
    }

    func testTheLastRowIsGreyAndRunsFromBlackToWhite() {
        for column in 0..<24 {
            let colour = ColourPicker.colour(row: ColourPicker.levels, column: column,
                                             hues: 24)
            let hex = colour.dropFirst()
            XCTAssertEqual(String(hex.prefix(2)), String(hex.dropFirst(2).prefix(2)), colour)
            XCTAssertEqual(String(hex.dropFirst(2).prefix(2)), String(hex.suffix(2)), colour)
        }
        XCTAssertEqual(ColourPicker.colour(row: ColourPicker.levels, column: 0, hues: 24),
                       "#000000")
        XCTAssertEqual(ColourPicker.colour(row: ColourPicker.levels, column: 23, hues: 24),
                       "#FFFFFF")
    }

    func testLowerRowsAreDarker() {
        func luminance(_ hex: String) -> Int {
            let value = Int(hex.dropFirst(), radix: 16) ?? 0
            return 299 * ((value >> 16) & 0xFF) + 587 * ((value >> 8) & 0xFF)
                + 114 * (value & 0xFF)
        }
        for row in 0..<(ColourPicker.levels - 1) {
            XCTAssertGreaterThan(
                luminance(ColourPicker.colour(row: row, column: 6, hues: 24)),
                luminance(ColourPicker.colour(row: row + 1, column: 6, hues: 24)),
                "row \(row) should be lighter than row \(row + 1)")
        }
    }

    // MARK: Opening where the value already is

    func testItOpensOnWhateverIsAlreadyThere() {
        XCTAssertEqual(ColourPicker(start: "#000000").current, "#000000")
        XCTAssertEqual(ColourPicker(start: "#FFFFFF").current, "#FFFFFF")
        // The value is held as HSL and converted back, so it must survive the round trip.
        XCTAssertEqual(ColourPicker(start: "#68B0F8").current, "#68B0F8")
        XCTAssertEqual(ColourPicker(start: "#A0D070").current, "#A0D070")
    }

    func testAnEmptyOrRubbishStartIsNotAnError() {
        XCTAssertNotNil(Color.hex(ColourPicker(start: nil).current))
        XCTAssertNotNil(Color.hex(ColourPicker(start: "none").current))
        XCTAssertNotNil(Color.hex(ColourPicker(start: "").current))
    }

    // MARK: Getting exactly the colour wanted

    /// The sliders reach colours the grid does not; one step is 0.01.
    func testASliderMovesOneStepAtATime() {
        var picker = ColourPicker(start: "#808080")
        _ = picker.handle(.tab)                      // onto the sliders
        XCTAssertEqual(picker.pane, .sliders)

        let before = picker.lightnessForTests
        _ = picker.handle(.down)                     // hue -> saturation -> lightness
        _ = picker.handle(.down)
        _ = picker.handle(.right)
        XCTAssertEqual(picker.lightnessForTests, before + 0.01, accuracy: 0.0001)
    }

    func testThePageKeysMoveTenAtATime() {
        var picker = ColourPicker(start: "#808080")
        _ = picker.handle(.tab)
        let before = picker.hueForTests
        _ = picker.handle(.pageUp)
        XCTAssertEqual(picker.hueForTests, before + 10, accuracy: 0.0001)
    }

    func testASliderStopsAtTheEndsRatherThanWrappingPast() {
        var picker = ColourPicker(start: "#808080")
        _ = picker.handle(.tab)
        _ = picker.handle(.down)                     // saturation
        for _ in 0..<200 { _ = picker.handle(.left) }
        XCTAssertEqual(picker.saturationForTests, 0, accuracy: 0.0001)
        for _ in 0..<400 { _ = picker.handle(.right) }
        XCTAssertEqual(picker.saturationForTests, 1, accuracy: 0.0001)
    }

    /// Hue is a circle: it wraps rather than stopping, and stays within 0..<360.
    func testHueWrapsRoundTheCircle() {
        var picker = ColourPicker(start: "#FF0000")
        _ = picker.handle(.tab)
        for _ in 0..<40 { _ = picker.handle(.left) }
        XCTAssertGreaterThanOrEqual(picker.hueForTests, 0)
        XCTAssertLessThan(picker.hueForTests, 360)
    }

    /// A hex converted to HSL and back comes out as the same hex.
    func testAnyColourSurvivesTheRoundTripThroughHSL() {
        for hex in ["#000000", "#FFFFFF", "#68B0F8", "#A0D070", "#D40000", "#123456",
                    "#7F7F7F", "#FF00FF", "#010203"] {
            XCTAssertEqual(ColourPicker(start: hex).current, hex, hex)
        }
    }

    // MARK: The style's own colours

    /// Colours already used by the style are offered as a pane and chosen exactly.
    func testTheStylesOwnColoursAreOfferedAndChosenExactly() {
        var picker = ColourPicker(start: "#000000", palette: ["#A0D070", "#204020"])
        _ = picker.handle(.tab)                      // sliders
        _ = picker.handle(.tab)                      // the style's colours
        XCTAssertEqual(picker.pane, .palette)

        guard case .chose(let first) = picker.handle(.enter) else {
            return XCTFail("enter should take the colour under the cursor")
        }
        XCTAssertEqual(first, "#A0D070")
    }

    func testTheStylePaneIsSkippedWhereThereIsNoPalette() {
        var picker = ColourPicker(start: "#000000")
        _ = picker.handle(.tab)
        _ = picker.handle(.tab)
        XCTAssertEqual(picker.pane, .grid, "an empty pane is not worth stopping on")
    }

    func testAColourListedTwiceIsOfferedOnce() {
        let picker = ColourPicker(start: nil, palette: ["#A0D070", "#a0d070", "#204020"])
        XCTAssertEqual(picker.palette, ["#A0D070", "#204020"])
    }

    // MARK: Walking the grid

    func testMovingStaysInsideTheGrid() {
        var picker = ColourPicker(start: "#808080")
        for _ in 0..<80 { _ = picker.handle(.left); _ = picker.handle(.up) }
        XCTAssertNotNil(Color.hex(picker.current))
        for _ in 0..<80 { _ = picker.handle(.right); _ = picker.handle(.down) }
        XCTAssertNotNil(Color.hex(picker.current))
    }

    func testEnterTakesWhatIsUnderTheCursorAndEscapeTakesNothing() {
        var picker = ColourPicker(start: "#FFFFFF")
        let expected = picker.current
        guard case .chose(let colour) = picker.handle(.enter) else {
            return XCTFail("enter should choose")
        }
        XCTAssertEqual(colour, expected)
        guard case .cancelled = picker.handle(.esc) else {
            return XCTFail("escape should cancel")
        }
    }

    // MARK: Reaching a command in any alphabet

    /// A command is bound to a place on the keyboard, not to a letter: a Cyrillic layout
    /// sends another character from that place, which must still reach the command.
    func testACommandKeyIsFoundByItsPlaceNotItsLetter() {
        XCTAssertEqual(Keys.latin("ф"), "a")
        XCTAssertEqual(Keys.latin("и"), "b")
        XCTAssertEqual(Keys.latin("в"), "d")
        XCTAssertEqual(Keys.latin("ч"), "x")
        XCTAssertEqual(Keys.latin("т"), "n")
        XCTAssertEqual(Keys.latin("д"), "l")
        XCTAssertEqual(Keys.latin("к"), "r")
        XCTAssertEqual(Keys.latin("ы"), "s")
        XCTAssertEqual(Keys.latin("ь"), "m")
        XCTAssertEqual(Keys.latin("ш"), "i")
        XCTAssertEqual(Keys.latin("у"), "e")
    }

    func testALatinKeyIsItselfAndCaseDoesNotMatter() {
        XCTAssertEqual(Keys.latin("a"), "a")
        XCTAssertEqual(Keys.latin("A"), "a")
        XCTAssertEqual(Keys.latin("Ф"), "a")
        XCTAssertEqual(Keys.latin("/"), "/")
        XCTAssertEqual(Keys.latin("7"), "7")
    }

    /// Every letter a command is bound to is reachable from a Cyrillic layout.
    func testEveryCommandLetterHasACyrillicKeyThatReachesIt() {
        let commands: Set<Character> = ["a", "c", "d", "i", "l", "m", "n", "r", "s", "u",
                                        "x", "y"]
        let reachable = Set("йцукенгшщзхъфывапролджэячсмитьбю".map(Keys.latin))
        for command in commands {
            XCTAssertTrue(reachable.contains(command),
                          "\(command) cannot be typed on a Russian layout")
        }
    }
}
