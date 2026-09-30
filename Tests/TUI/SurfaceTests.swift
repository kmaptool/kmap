import XCTest

@testable import kmap

/// The text helpers every screen is drawn through. `stripControlSequences` matters
/// beyond looks: mkgmap, Java and pyhgtmap all print escape sequences, and the log they
/// land in is painted onto a terminal already in raw mode.
final class SurfaceTests: XCTestCase {
    // MARK: Wrapping

    func testTextIsBrokenOnSpacesWhenItCan() {
        XCTAssertEqual(
            wrapText("the quick brown fox", width: 10),
            ["the quick", "brown fox"]
        )
        XCTAssertEqual(wrapText("short", width: 10), ["short"])
        XCTAssertEqual(wrapText("exactly-10", width: 10), ["exactly-10"])
    }

    func testAWordLongerThanTheColumnIsCutRatherThanLost() {
        // A URL or a path in a warning: it has to appear, even broken.
        XCTAssertEqual(
            wrapText("supercalifragilistic", width: 8),
            ["supercal", "ifragili", "stic"]
        )
    }

    func testExplicitLineBreaksAreKeptIncludingTheEmptyOnes() {
        // The help screen is written as paragraphs; losing blank lines runs them together.
        XCTAssertEqual(wrapText("one\n\ntwo", width: 10), ["one", "", "two"])
        XCTAssertEqual(wrapText("", width: 10), [""])
    }

    func testTabsBecomeSpacesSoTheyDoNotJumpTheCursor() {
        // A terminal advances a tab to the next stop, which is not where the surface
        // thinks the cursor is; everything after it on the row lands in the wrong column.
        XCTAssertEqual(wrapText("a\tb", width: 20), ["a    b"])
    }

    func testANonsenseWidthReturnsTheTextRatherThanLoopingForEver() {
        XCTAssertEqual(wrapText("anything", width: 0), ["anything"])
        XCTAssertEqual(wrapText("anything", width: -5), ["anything"])
    }

    // MARK: Truncating

    func testTruncationLeavesRoomForTheMarkThatSaysItHappened() {
        XCTAssertEqual(truncate("abcdefgh", to: 5), "abcd\(Glyph.ellipsis)")
        XCTAssertEqual(truncate("abc", to: 5), "abc")
        XCTAssertEqual(truncate("abcde", to: 5), "abcde")
    }

    func testTruncatingToNothingIsNotAnError() {
        XCTAssertEqual(truncate("abc", to: 0), "")
        XCTAssertEqual(truncate("abc", to: -1), "")
        // One column has no room for both a letter and the mark.
        XCTAssertEqual(truncate("abc", to: 1), "a")
    }

    // MARK: Escapes from other programs

    func testColourSequencesAreRemovedWithoutTakingTheTextWithThem() {
        XCTAssertEqual(stripControlSequences("\u{1B}[32mdone\u{1B}[0m"), "done")
        XCTAssertEqual(stripControlSequences("a\u{1B}[1;31mb\u{1B}[mc"), "abc")
    }

    func testATitleSequenceIsRemovedWholeHoweverItEnds() {
        // A tool that retitles the terminal: "ESC ] 0 ; text BEL", or ending with ESC \.
        XCTAssertEqual(stripControlSequences("\u{1B}]0;a title\u{07}after"), "after")
        XCTAssertEqual(stripControlSequences("\u{1B}]0;a title\u{1B}\\after"), "after")
    }

    func testAnEscapeWithNothingBehindItDoesNotRunOffTheEnd() {
        XCTAssertEqual(stripControlSequences("text\u{1B}"), "text")
        XCTAssertEqual(stripControlSequences("text\u{1B}["), "text")
        XCTAssertEqual(stripControlSequences("\u{1B}]0;unterminated"), "")
    }

    func testCursorMovementIsRemovedRatherThanDrawnOverTheInterface() {
        // Java's progress output moves the cursor and clears the line; let through, it
        // erases whatever kmap has painted there.
        XCTAssertEqual(stripControlSequences("\u{1B}[2K\u{1B}[1Gbuilding"), "building")
        XCTAssertEqual(stripControlSequences("\u{1B}[?25lhidden cursor"), "hidden cursor")
    }

    func testControlCharactersGoButTabsAndNewlinesStay() {
        // Those two the surface handles itself; the rest would move a real terminal.
        XCTAssertEqual(stripControlSequences("a\u{07}b\u{08}c"), "abc")
        XCTAssertEqual(stripControlSequences("a\tb\nc"), "a\tb\nc")
        XCTAssertEqual(stripControlSequences("a\u{7F}b"), "ab")
    }

    func testLettersOutsideASCIISurviveWhateverAlphabetTheyAreIn() {
        // Names arrive in their own script, and the log carries them.
        XCTAssertEqual(
            stripControlSequences("Прибрежный административный округ"),
            "Прибрежный административный округ"
        )
        XCTAssertEqual(stripControlSequences("Küsten-Größenregion"), "Küsten-Größenregion")
        XCTAssertEqual(stripControlSequences("地図 · 地域"), "地図 · 地域")
        XCTAssertEqual(stripControlSequences("→ ✓ ✗"), "→ ✓ ✗")
    }

    func testPlainTextIsHandedBackUnchanged() {
        let plain = "7 tile(s), 41.9 MB in all"
        XCTAssertEqual(stripControlSequences(plain), plain)
        XCTAssertEqual(stripControlSequences(""), "")
    }

    // MARK: Characters two columns wide

    func testAWideCharacterTakesTwoColumnsAndTheRowStaysInStep() {
        let surface = Surface()
        surface.resize(10, 1)
        surface.clear(.plain)
        let end = surface.text(0, 0, "a中b", .plain)
        XCTAssertEqual(end, 4, "one narrow, one wide, one narrow")
        XCTAssertEqual(surface.cell(3, 0)?.ch, "b")
        XCTAssertEqual(surface.cell(2, 0)?.ch, Surface.wideFiller)
        // The frame sends the wide glyph once and nothing for its second column.
        let row = stripControlSequences(surface.compose())
        XCTAssertTrue(row.contains("a中b"))
        XCTAssertEqual(surface.asText(), "a中 b".replacingOccurrences(of: " b", with: " b"))
    }

    func testOverwritingHalfAWideCharacterClearsTheOtherHalf() {
        let surface = Surface()
        surface.resize(6, 1)
        surface.clear(.plain)
        surface.text(0, 0, "中", .plain)
        surface.put(0, 0, "x", .plain)
        XCTAssertEqual(surface.cell(1, 0)?.ch, " ", "the filler went with the glyph")
        surface.text(2, 0, "中", .plain)
        surface.put(3, 0, "y", .plain)
        XCTAssertEqual(surface.cell(2, 0)?.ch, " ", "the glyph went with its filler")
    }

    func testAWideCharacterAtTheEdgeIsNotDrawnByHalf() {
        let surface = Surface()
        surface.resize(3, 1)
        surface.clear(.plain)
        surface.text(0, 0, "ab中", .plain)
        XCTAssertEqual(surface.cell(2, 0)?.ch, " ")
    }

    func testWidthsTruncationAndRightAlignmentCountColumns() {
        XCTAssertEqual(Text.cellWidth("Крым"), 4)
        XCTAssertEqual(Text.cellWidth("中文"), 4)
        XCTAssertEqual(Text.cellWidth("e\u{0301}"), 1, "a combining accent adds nothing")
        XCTAssertEqual(Text.cellWidth("\u{1F600}"), 2)
        XCTAssertEqual(truncate("中文字", to: 4), "中" + String(Glyph.ellipsis))
        XCTAssertEqual(truncate("abc", to: 3), "abc")
        XCTAssertEqual(wrapText("中文字", width: 1), ["中", "文", "字"])
        let surface = Surface()
        surface.resize(6, 1)
        surface.clear(.plain)
        surface.textRight(6, 0, "中b", .plain)
        XCTAssertEqual(surface.cell(3, 0)?.ch, "中")
        XCTAssertEqual(surface.cell(5, 0)?.ch, "b")
    }

    func testAFillerFollowsOnlyAGlyphThatIsWideAsDrawn() {
        // The console may be sent a narrow stand-in (on Windows the fullwidth plus of
        // the icon screen is drawn as a plain one): a filler behind it would put the rest
        // of the row a column out, so the width is the drawn glyph's.
        for key in Array(Glyph.windowsSubstitutes.keys) + ["中", "a"] {
            let surface = Surface()
            surface.resize(4, 1)
            surface.clear(.plain)
            let end = surface.text(0, 0, String(key) + "a", .plain)
            guard let drawn = surface.cell(0, 0)?.ch else { return XCTFail("nothing drawn for \(key)") }
            let wide = Text.cellWidth(drawn) == 2
            XCTAssertEqual(surface.cell(1, 0)?.ch == Surface.wideFiller, wide, "\(key) drawn as \(drawn)")
            XCTAssertEqual(end, wide ? 3 : 2, "\(key): the next letter follows the drawn glyph")
        }
    }
}
