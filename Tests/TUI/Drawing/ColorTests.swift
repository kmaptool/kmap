import XCTest

@testable import kmap

/// Colour handling: the interface palette stays at 256 entries, while a colour read out of
/// a TYP is emitted exactly where the terminal supports true colour and folded onto the
/// palette where it does not.
final class ColorTests: XCTestCase {
    // MARK: Reading a TYP colour

    func testAHexColourIsReadTheWayATypWritesIt() {
        XCTAssertEqual(Color.hex("#68B0F8"), .rgb(0x68, 0xB0, 0xF8))
        XCTAssertEqual(Color.hex("68B0F8"), .rgb(0x68, 0xB0, 0xF8))
        XCTAssertEqual(Color.hex("  #A0D070  "), .rgb(0xA0, 0xD0, 0x70))
    }

    /// `none` is transparency, not a colour. A caller has to draw something else for it.
    func testTransparencyAndRubbishAreNotColours() {
        XCTAssertNil(Color.hex("none"))
        XCTAssertNil(Color.hex(""))
        XCTAssertNil(Color.hex("#12345"))
        XCTAssertNil(Color.hex("#GGGGGG"))
    }

    // MARK: What goes on the wire

    func testATrueColourStyleEmitsTheExactValue() {
        let style = Style(fg: .rgb(0x68, 0xB0, 0xF8), bg: .rgb(0, 0, 0))
        XCTAssertEqual(style.sgr(trueColour: true), "\u{1B}[0;38;2;104;176;248;48;2;0;0;0m")
    }

    func testAPaletteStyleIsUnchangedByAnyOfThis() {
        let style = Style(fg: .xterm(252), bg: .xterm(233), bold: true)
        XCTAssertEqual(style.sgr(), "\u{1B}[0;1;38;5;252;48;5;233m")
        XCTAssertEqual(style.sgr(trueColour: false), style.sgr(trueColour: true))
    }

    func testTheTerminalDefaultEmitsNoColourAtAll() {
        XCTAssertEqual(Style.plain.sgr(), "\u{1B}[0m")
    }

    func testWithoutTrueColourAValueIsFoldedOntoThePalette() {
        let style = Style(fg: .rgb(0x68, 0xB0, 0xF8))
        let folded = style.sgr(trueColour: false)
        XCTAssertFalse(folded.contains("38;2;"), "no 24-bit sequence should reach the terminal")
        XCTAssertTrue(folded.contains("38;5;"))
    }

    // MARK: The approximation itself

    func testAColourSittingOnACubeLevelLandsExactlyOnIt() {
        // The cube runs 0, 95, 135, 175, 215, 255 per channel; 16 + 36r + 6g + b.
        XCTAssertEqual(Color.rgb(0, 0, 0).paletteApproximation, 16)
        XCTAssertEqual(Color.rgb(255, 255, 255).paletteApproximation, 231)
        XCTAssertEqual(Color.rgb(255, 0, 0).paletteApproximation, 196)
    }

    /// The cube's greys are 40 units apart, so a neutral quantized against the cube alone
    /// would drift into whichever channel rounds up.
    func testANeutralGreyIsQuantizedAgainstTheGreyRampRatherThanTheCube() {
        let index = Color.rgb(120, 120, 120).paletteApproximation
        XCTAssertGreaterThanOrEqual(index, 232, "should land on the grey ramp")
        XCTAssertLessThanOrEqual(index, 255)
    }

    func testAPaletteColourApproximatesToItself() {
        XCTAssertEqual(Color.xterm(74).paletteApproximation, 74)
    }

    /// Two colours far enough apart do not collapse onto one palette entry.
    func testDistinctColoursStayDistinctThroughTheFold() {
        XCTAssertNotEqual(
            Color.hex("#68B0F8")?.paletteApproximation,
            Color.hex("#A0D070")?.paletteApproximation
        )
    }

    /// Hex digits only: a sign would be written into a TYP and crash mkgmap's reader.
    func testAColourTakesHexDigitsOnlyAndShowsWithoutItsAlpha() {
        XCTAssertNil(Color.channels(of: "+12345"))
        XCTAssertNil(Color.channels(of: "#-1234567"))
        XCTAssertEqual(Color.channels(of: "#FF000077").map { [$0.0, $0.1, $0.2] }, [255, 0, 0])
    }
}
