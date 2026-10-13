import XCTest

@testable import kmap

/// Reading a whole TYP source. Parsing is half a round trip, so the file must reassemble
/// byte for byte.
final class TypSourceParserTests: XCTestCase {
    /// Reassembly must be byte-identical: an edit replaces named lines inside a section's
    /// range, so any perturbation in parsing would rewrite unrelated lines.
    func testARealisticTypComesBackOutExactlyAsItWentIn() {
        let original = TypFixture.source
        XCTAssertEqual(TypSource.parse(original).text, original)
    }

    func testAFileWithNoTrailingNewlineIsNotGivenOne() {
        let text = "[_id]\nFID=1\n[end]"
        XCTAssertEqual(TypSource.parse(text).text, text)
    }

    func testBlankLinesAndIndentationSurviveParsing() {
        let text = "\n\n[_polygon]\n  Type=0x16\n\n  Xpm=\"0 0 1 0\"\n  \"a c #A0D070\"\n[end]\n\n"
        XCTAssertEqual(TypSource.parse(text).text, text)
    }

    func testTheIdBlockIsRead() {
        let source = TypSource.parse("[_id]\nFID=6324\nProductCode=1\nCodePage=1252\n[end]\n")
        XCTAssertEqual(source.familyID, 6324)
        XCTAssertEqual(source.productID, 1)
        XCTAssertEqual(source.codePage, 1252)
    }

    /// A section's comments, above it and inside it, belong to that section.
    func testTheCommentsAboveASectionBelongToIt() throws {
        let source = TypSource.parse(
            """
            ; Restaurant.  Imported from a reference product (family 9469).
            [_point]
            Type=0x2a00
            ; red badge, white knife and fork
            [end]
            """
        )
        let comments = try XCTUnwrap(source.section(.point, 0x2a00)?.comments)
        XCTAssertEqual(comments.count, 2)
        XCTAssertTrue(comments[0].contains("reference product"))
        XCTAssertTrue(comments[1].contains("knife and fork"))
    }

    func testAWholeFileParsesIntoEverySectionItHolds() throws {
        let source = TypSource.parse(TypFixture.source)

        XCTAssertEqual(source.familyID, 6324)
        XCTAssertEqual(source.productID, 1)
        XCTAssertEqual(source.codePage, 1252)

        XCTAssertEqual(source.sections(.point).count, TypFixture.pointCount)
        XCTAssertEqual(source.sections(.line).count, TypFixture.lineCount)
        XCTAssertEqual(source.sections(.polygon).count, TypFixture.polygonCount)

        XCTAssertEqual(
            source.polygonsMissingFromDrawOrder,
            [],
            "a styled polygon absent from [_drawOrder] is never drawn"
        )

        // Language 0x00 is the fallback where the device's own language has no entry.
        let unlabelled = source.sections.filter { $0.englishLabel == nil }
        XCTAssertEqual(unlabelled.map(\.hex), [], "sections with no English fallback label")
    }

    /// Checks the TYP library rather than a fixture, since the repository ships no TYP.
    /// Skipped where the library is empty.
    func testEveryTypSourceInTheLibraryParsesAndComesBackUnchanged() throws {
        let sources = TypLibrary.contents().filter { $0.pathExtension.lowercased() == "txt" }
        try XCTSkipIf(sources.isEmpty, "no TYP source in this machine's library")

        for url in sources {
            let original = try String(contentsOf: url, encoding: .utf8)
            let source = TypSource.parse(original)
            XCTAssertEqual(source.text, original, url.lastPathComponent)
            XCTAssertNotNil(source.familyID, url.lastPathComponent)
            // Draw-order completeness is not asserted: it is a property of the file's author,
            // and imported styles routinely omit entries.
            for section in source.sections {
                guard let picture = section.picture else { continue }
                XCTAssertEqual(
                    picture.palette.count,
                    picture.declaredColours,
                    "\(url.lastPathComponent) \(section.hex)"
                )
                XCTAssertEqual(
                    picture.rows.count,
                    picture.height,
                    "\(url.lastPathComponent) \(section.hex)"
                )
            }
        }
    }

    /// A source saved with CRLF parses the same. `CharacterSet.whitespaces` is Zs plus tab
    /// and excludes the carriage return, so an unstripped one hides every `[end]`.
    func testASourceSavedWithWindowsLineEndingsParsesTheSame() {
        let unix = """
            ;kmap
            [_point]
            Type=0x2a00
            String1=0x00,Something
            [end]
            [_polygon]
            Type=0x16
            [end]
            """
        let windows = unix.replacingOccurrences(of: "\n", with: "\r\n")

        let a = TypSource.parse(unix)
        let b = TypSource.parse(windows)
        XCTAssertFalse(a.sections.isEmpty, "the fixture itself has to parse")
        XCTAssertEqual(b.sections.count, a.sections.count)
        XCTAssertEqual(b.codes(.point), a.codes(.point))
        XCTAssertEqual(b.codes(.polygon), a.codes(.polygon))
        XCTAssertEqual(
            b.section(.point, 0x2a00)?.englishLabel,
            a.section(.point, 0x2a00)?.englishLabel
        )
    }

    func testTheHeaderNumbersSurviveWindowsLineEndingsToo() {
        // A trailing carriage return makes the value unparseable as a number, leaving the
        // family id nil.
        let source = TypSource.parse("[_id]\r\nFID=1540\r\nProductCode=25\r\nCodePage=1251\r\n[end]\r\n")
        XCTAssertEqual(source.familyID, 1540)
        XCTAssertEqual(source.productID, 25)
        XCTAssertEqual(source.codePage, 1251)
    }

    /// A point's `Type=0x2f` is 0x2f00 to mkgmap, as `Type=0x2f` with `SubType=0x00` is.
    func testAPointWithAShortTypeIsItsCodeWithSubtypeNothing() {
        let source = TypSource.parse("[_point]\nType=0x2f\n[end]\n[_point]\nType=0x2a\nSubType=0x01\n[end]")
        XCTAssertEqual(source.sections.map(\.code), [0x2f00, 0x2a01])
    }

    /// A point's type and subtype as mkgmap reads them: the later line wins.
    func testAPointsSubtypeIsReadInTheOrderTheLinesComeIn() {
        func code(_ body: String) -> [Int] {
            TypSource.parse("[_point]\n\(body)\n[end]").sections.map(\.code)
        }
        XCTAssertEqual(code("SubType=0x05\nType=0x2f"), [0x2f05])
        XCTAssertEqual(code("Type=0x2f05\nSubType=0x01"), [0x2f01])
        XCTAssertEqual(code("Type=0x2f\nSubType=0x03"), [0x2f03])
        XCTAssertEqual(code("Type=0x2f"), [0x2f00])
        XCTAssertEqual(code("Type=0x11605"), [0x11605])
    }

    /// Numbers a damaged file can hold, read without a trap.
    func testWildNumbersDoNotTrap() {
        let text = """
            [_point]
            Type=0x2f00
            DayXpm="9223372036854775807 1 1 2"
            "ab c #FF0000" alpha=560000000000000000
            "ab"
            [end]
            """
        let source = TypSource.parse(text)
        XCTAssertNotNil(source.section(.point, 0x2f00))
    }
}
