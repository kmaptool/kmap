import XCTest

@testable import kmap

/// Covers splitting text into lines.
///
/// Swift treats `\r\n` as one `Character`, so `split(separator: "\n")` returns a CRLF file
/// as a single line, as does `components(separatedBy:)` on Linux.
final class TextLinesTests: XCTestCase {
    func testUnixLineEndings() {
        XCTAssertEqual(TextLines.of("a\nb\nc"), ["a", "b", "c"])
    }

    func testWindowsLineEndings() {
        XCTAssertEqual(TextLines.of("a\r\nb\r\nc"), ["a", "b", "c"])
    }

    func testTheClassicMacLineEnding() {
        // A lone carriage return must not come back as a single line either.
        XCTAssertEqual(TextLines.of("a\rb\rc"), ["a", "b", "c"])
    }

    func testMixedEndingsInOneFile() {
        XCTAssertEqual(TextLines.of("a\r\nb\nc\rd"), ["a", "b", "c", "d"])
    }

    func testATrailingNewlineDoesNotAddAnEmptyLine() {
        XCTAssertEqual(TextLines.of("a\nb\n"), ["a", "b"])
        XCTAssertEqual(TextLines.of("a\r\nb\r\n"), ["a", "b"])
    }

    func testEmptyLinesInTheMiddleAreKept() {
        // A TYP source separates its sections with them.
        XCTAssertEqual(TextLines.of("a\n\nb"), ["a", "", "b"])
        XCTAssertEqual(TextLines.of("a\r\n\r\nb"), ["a", "", "b"])
    }

    func testNothingIsNoLines() {
        XCTAssertEqual(TextLines.of(""), [])
        XCTAssertEqual(TextLines.of("\n"), [""])
        XCTAssertEqual(TextLines.of("\r\n"), [""])
    }

    func testTheRoundTripFormKeepsTheBlankATrailingNewlineImplies() {
        // The `components(separatedBy:)` shape: a file that ended in a newline still ends
        // in one after being rejoined.
        XCTAssertEqual(TextLines.keepingTrailingBlank("a\nb\n"), ["a", "b", ""])
        XCTAssertEqual(TextLines.keepingTrailingBlank("a\r\nb\r\n"), ["a", "b", ""])
        XCTAssertEqual(TextLines.keepingTrailingBlank("a\nb"), ["a", "b"])
        XCTAssertEqual(TextLines.keepingTrailingBlank("a\n\n"), ["a", "", ""])
    }

    func testTextWithNoEndingAtAllIsOneLine() {
        XCTAssertEqual(TextLines.of("just the one"), ["just the one"])
    }

    func testNonAsciiSurvives() {
        XCTAssertEqual(TextLines.of("Москва\r\nСимферополь\n"), ["Москва", "Симферополь"])
    }

    func testTheLineEndingIsGoneRatherThanTrimmed() {
        // Trimming with `.whitespaces` would not do it: that set is Zs plus tab, and holds
        // no carriage return.
        let lines = TextLines.of("  [end]  \r\n")
        XCTAssertEqual(lines, ["  [end]  "])
        XCTAssertEqual(lines[0].trimmingCharacters(in: .whitespaces), "[end]")
    }

    // MARK: What the obvious ways actually do

    func testWhyThisExistsAtAll() {
        // Pins the standard library behaviour this helper exists for.
        let windows = "[_id]\r\nFID=1540\r\n[end]\r\n"
        XCTAssertEqual(
            windows.split(separator: "\n").count,
            1,
            "`split` sees one line, because \\r\\n is one Character"
        )
        XCTAssertEqual(TextLines.of(windows), ["[_id]", "FID=1540", "[end]"])
    }
}
