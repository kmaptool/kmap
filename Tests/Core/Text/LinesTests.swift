import XCTest
@testable import kmap

/// Covers splitting text into lines.
///
/// Swift treats `\r\n` as one `Character`, so `split(separator: "\n")` returns a CRLF file
/// as a single line, as does `components(separatedBy:)` on Linux.
final class LinesTests: XCTestCase {

    func testUnixLineEndings() {
        XCTAssertEqual(Lines.of("a\nb\nc"), ["a", "b", "c"])
    }

    func testWindowsLineEndings() {
        XCTAssertEqual(Lines.of("a\r\nb\r\nc"), ["a", "b", "c"])
    }

    func testTheClassicMacLineEnding() {
        // A lone carriage return must not come back as a single line either.
        XCTAssertEqual(Lines.of("a\rb\rc"), ["a", "b", "c"])
    }

    func testMixedEndingsInOneFile() {
        XCTAssertEqual(Lines.of("a\r\nb\nc\rd"), ["a", "b", "c", "d"])
    }

    func testATrailingNewlineDoesNotAddAnEmptyLine() {
        XCTAssertEqual(Lines.of("a\nb\n"), ["a", "b"])
        XCTAssertEqual(Lines.of("a\r\nb\r\n"), ["a", "b"])
    }

    func testEmptyLinesInTheMiddleAreKept() {
        // A TYP source separates its sections with them.
        XCTAssertEqual(Lines.of("a\n\nb"), ["a", "", "b"])
        XCTAssertEqual(Lines.of("a\r\n\r\nb"), ["a", "", "b"])
    }

    func testNothingIsNoLines() {
        XCTAssertEqual(Lines.of(""), [])
        XCTAssertEqual(Lines.of("\n"), [""])
        XCTAssertEqual(Lines.of("\r\n"), [""])
    }

    func testTheRoundTripFormKeepsTheBlankATrailingNewlineImplies() {
        // The `components(separatedBy:)` shape: a file that ended in a newline still ends
        // in one after being rejoined.
        XCTAssertEqual(Lines.keepingTrailingBlank("a\nb\n"), ["a", "b", ""])
        XCTAssertEqual(Lines.keepingTrailingBlank("a\r\nb\r\n"), ["a", "b", ""])
        XCTAssertEqual(Lines.keepingTrailingBlank("a\nb"), ["a", "b"])
        XCTAssertEqual(Lines.keepingTrailingBlank("a\n\n"), ["a", "", ""])
    }

    func testTextWithNoEndingAtAllIsOneLine() {
        XCTAssertEqual(Lines.of("just the one"), ["just the one"])
    }

    func testNonAsciiSurvives() {
        XCTAssertEqual(Lines.of("Москва\r\nСимферополь\n"), ["Москва", "Симферополь"])
    }

    func testTheLineEndingIsGoneRatherThanTrimmed() {
        // Trimming with `.whitespaces` would not do it: that set is Zs plus tab, and holds
        // no carriage return.
        let lines = Lines.of("  [end]  \r\n")
        XCTAssertEqual(lines, ["  [end]  "])
        XCTAssertEqual(lines[0].trimmingCharacters(in: .whitespaces), "[end]")
    }

    // MARK: What the obvious ways actually do

    func testWhyThisExistsAtAll() {
        // Pins the standard library behaviour this helper exists for.
        let windows = "[_id]\r\nFID=1540\r\n[end]\r\n"
        XCTAssertEqual(windows.split(separator: "\n").count, 1,
                       "`split` sees one line, because \\r\\n is one Character")
        XCTAssertEqual(Lines.of(windows), ["[_id]", "FID=1540", "[end]"])
    }
}
