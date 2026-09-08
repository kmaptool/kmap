import XCTest
@testable import kmap

/// The text helpers every screen is drawn through. `stripControlSequences` matters
/// beyond looks: mkgmap, Java and pyhgtmap all print escape sequences, and the log they
/// land in is painted onto a terminal already in raw mode.
final class SurfaceTests: XCTestCase {

    // MARK: Wrapping

    func testTextIsBrokenOnSpacesWhenItCan() {
        XCTAssertEqual(wrapText("the quick brown fox", width: 10),
                       ["the quick", "brown fox"])
        XCTAssertEqual(wrapText("short", width: 10), ["short"])
        XCTAssertEqual(wrapText("exactly-10", width: 10), ["exactly-10"])
    }

    func testAWordLongerThanTheColumnIsCutRatherThanLost() {
        // A URL or a path in a warning: it has to appear, even broken.
        XCTAssertEqual(wrapText("supercalifragilistic", width: 8),
                       ["supercal", "ifragili", "stic"])
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
        XCTAssertEqual(stripControlSequences("Прибрежный административный округ"),
                       "Прибрежный административный округ")
        XCTAssertEqual(stripControlSequences("Küsten-Größenregion"), "Küsten-Größenregion")
        XCTAssertEqual(stripControlSequences("地図 · 地域"), "地図 · 地域")
        XCTAssertEqual(stripControlSequences("→ ✓ ✗"), "→ ✓ ✗")
    }

    func testPlainTextIsHandedBackUnchanged() {
        let plain = "7 tile(s), 41.9 MB in all"
        XCTAssertEqual(stripControlSequences(plain), plain)
        XCTAssertEqual(stripControlSequences(""), "")
    }
}
