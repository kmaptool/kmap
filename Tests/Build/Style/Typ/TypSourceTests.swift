import XCTest
@testable import kmap

/// Reading an mkgmap TYP *source* file. Parsing is half a round trip, so the file must
/// reassemble byte for byte.
final class TypSourceTests: XCTestCase {

    // MARK: The property everything else rests on

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

    // MARK: Identity

    func testTheIdBlockIsRead() {
        let source = TypSource.parse("[_id]\nFID=6324\nProductCode=1\nCodePage=1252\n[end]\n")
        XCTAssertEqual(source.familyID, 6324)
        XCTAssertEqual(source.productID, 1)
        XCTAssertEqual(source.codePage, 1252)
    }

    // MARK: Sections

    func testASolidPolygonIsReadAsColoursRatherThanAPicture() throws {
        let source = TypSource.parse("""
            [_polygon]
            Type=0x16
            Xpm="0 0 2 0"
            "a c #A0D070"
            "b c #204020"
            String=0x00,Nature reserve
            [end]
            """)
        let section = try XCTUnwrap(source.section(.polygon, 0x16))
        let xpm = try XCTUnwrap(section.xpm)
        XCTAssertTrue(xpm.isSolid)
        XCTAssertEqual(xpm.colours, ["#A0D070", "#204020"], "day then night")
        XCTAssertNil(section.picture, "a solid block has no picture to draw")
        XCTAssertEqual(section.englishLabel, "Nature reserve")
    }

    func testATransparentPaletteSlotIsReadAsTransparentRatherThanAsBlack() throws {
        // `none` is a transparent slot; read as a colour it would flood the polygon.
        let source = TypSource.parse("""
            [_line]
            Type=0x23
            Xpm="4 1 2 1"
            "! c #789400"
            ". c none"
            "!..!"
            [end]
            """)
        let picture = try XCTUnwrap(source.section(.line, 0x23)?.picture)
        XCTAssertEqual(picture.pixels()?.first ?? [], ["#789400", nil, nil, "#789400"])
    }

    /// A semicolon is a legal palette key. Treating `;` as a comment marker without checking
    /// quoting truncates the palette, leaving pixels resolving against absent colours.
    func testASemicolonPaletteKeyIsNotMistakenForAComment() throws {
        let source = TypSource.parse("""
            [_point]
            Type=0x2a00
            DayXpm="2 1 2 1"
            "; c #FF0000"
            "a c #00FF00"
            ";a"
            [end]
            """)
        let picture = try XCTUnwrap(source.section(.point, 0x2a00)?.picture)
        XCTAssertEqual(picture.palette.count, 2)
        XCTAssertEqual(picture.pixels()?.first ?? [], ["#FF0000", "#00FF00"])
    }

    func testACommentOutsideQuotesIsStillStripped() {
        let source = TypSource.parse("[_id]\nFID=6324 ; the family id\n[end]\n")
        XCTAssertEqual(source.familyID, 6324)
    }

    func testLabelsKeepTheirLanguageIndex() throws {
        let source = TypSource.parse("""
            [_point]
            Type=0x2a00
            String=0x00,Restaurant
            String=0x19,Ресторан
            [end]
            """)
        let section = try XCTUnwrap(source.section(.point, 0x2a00))
        XCTAssertEqual(section.englishLabel, "Restaurant")
        XCTAssertEqual(section.russianLabel, "Ресторан")
    }

    func testALabelContainingACommaKeepsIt() throws {
        let source = TypSource.parse("""
            [_point]
            Type=0x6511
            String=0x00,Spring, drinking
            [end]
            """)
        XCTAssertEqual(source.section(.point, 0x6511)?.englishLabel, "Spring, drinking")
    }

    /// A section's comments, above it and inside it, belong to that section.
    func testTheCommentsAboveASectionBelongToIt() throws {
        let source = TypSource.parse("""
            ; Restaurant.  Imported from a reference product (family 9469).
            [_point]
            Type=0x2a00
            ; red badge, white knife and fork
            [end]
            """)
        let comments = try XCTUnwrap(source.section(.point, 0x2a00)?.comments)
        XCTAssertEqual(comments.count, 2)
        XCTAssertTrue(comments[0].contains("reference product"))
        XCTAssertTrue(comments[1].contains("knife and fork"))
    }

    // MARK: Changing the grid

    /// Growing pads with transparency, adding a transparent palette entry where there is
    /// none, rather than with the first colour in the palette.
    func testGrowingAPictureFillsTheNewGroundWithNothing() throws {
        let source = TypSource.parse("""
            [_point]
            Type=0x2a00
            DayXpm="2 2 1 1"
            "a c #FF0000"
            "aa"
            "aa"
            [end]
            """)
        let picture = try XCTUnwrap(source.section(.point, 0x2a00)?.picture)
        let grown = picture.resized(width: 4, height: 3)

        XCTAssertEqual(grown.width, 4)
        XCTAssertEqual(grown.height, 3)
        let grid = try XCTUnwrap(grown.pixels())
        XCTAssertEqual(grid[0], ["#FF0000", "#FF0000", nil, nil])
        XCTAssertEqual(grid[2], [nil, nil, nil, nil], "the new row is clear")
    }

    /// Cropping is anchored at the top-left.
    func testShrinkingKeepsTheTopLeft() throws {
        let source = TypSource.parse("""
            [_point]
            Type=0x2a00
            DayXpm="3 3 2 1"
            "a c #FF0000"
            "b c #0000FF"
            "aab"
            "aab"
            "bbb"
            [end]
            """)
        let picture = try XCTUnwrap(source.section(.point, 0x2a00)?.picture)
        let cropped = picture.resized(width: 2, height: 2)

        XCTAssertEqual(cropped.pixels(), [["#FF0000", "#FF0000"], ["#FF0000", "#FF0000"]])
    }

    /// A resized picture must still write back into a TYP and read the same.
    func testAResizedPictureSurvivesBeingWrittenOut() throws {
        let source = TypSource.parse("""
            [_point]
            Type=0x2a00
            DayXpm="2 2 1 1"
            "a c #FF0000"
            "aa"
            "aa"
            String=0x00,Something
            [end]
            """)
        let picture = try XCTUnwrap(source.section(.point, 0x2a00)?.picture)
        let edited = try TypEdit.setPicture(in: source, kind: .point, code: 0x2a00,
                                            to: picture.resized(width: 5, height: 5))
        let after = try XCTUnwrap(TypSource.parse(edited).section(.point, 0x2a00))

        XCTAssertEqual(after.picture?.width, 5)
        XCTAssertEqual(after.picture?.rows.count, 5)
        XCTAssertEqual(after.picture?.palette.count, after.picture?.declaredColours)
        XCTAssertEqual(after.englishLabel, "Something")
    }

    // MARK: Saying a gap is on purpose

    /// A `; kmap:unstyled` marker records types the file leaves to the device, so a coverage
    /// report does not flag them.
    func testAFileCanSayWhichTypesItLeavesToTheDeviceOnPurpose() {
        let source = TypSource.parse("""
            ; kmap:unstyled lines 0x01 0x02 0x03 — the road hierarchy, left to the device
            [_line]
            Type=0x16
            Xpm="0 0 1 0"
            "a c #303030"
            [end]
            """)
        XCTAssertEqual(source.deliberatelyUnstyled[.line], [0x01, 0x02, 0x03])
        XCTAssertNil(source.deliberatelyUnstyled[.polygon])
    }

    func testTheMarkerNamesItsKindTheWayTheInterfaceDoes() {
        XCTAssertEqual(TypSource.parse("; kmap:unstyled polygons 0x0a\n")
            .deliberatelyUnstyled[.polygon], [0x0a])
        XCTAssertEqual(TypSource.parse("; kmap:unstyled point 0x2a00\n")
            .deliberatelyUnstyled[.point], [0x2a00])
    }

    /// Markers for one kind union rather than replacing one another.
    func testSeveralMarkersForOneKindCombine() {
        let source = TypSource.parse("""
            ; kmap:unstyled lines 0x01 0x02 — motorway and trunk
            ; kmap:unstyled lines 0x0b 0x0c — the link roads
            """)
        XCTAssertEqual(source.deliberatelyUnstyled[.line], [0x01, 0x02, 0x0b, 0x0c])
    }

    /// A malformed marker stays an ordinary comment, so a mistyped claim silences nothing.
    func testAMalformedMarkerIsJustAComment() {
        XCTAssertTrue(TypSource.parse("; kmap:unstyled 0x01\n").deliberatelyUnstyled.isEmpty)
        XCTAssertTrue(TypSource.parse("; kmap:unstyled ways 0x01\n").deliberatelyUnstyled.isEmpty)
        XCTAssertTrue(TypSource.parse("; kmap:unstyled lines\n").deliberatelyUnstyled.isEmpty)
        XCTAssertTrue(TypSource.parse("; a normal comment\n").deliberatelyUnstyled.isEmpty)
    }

    func testTheMarkerIsStillACommentAndSurvivesUntouched() {
        let text = "; kmap:unstyled lines 0x01 — because\n[_line]\nType=0x16\n[end]\n"
        XCTAssertEqual(TypSource.parse(text).text, text)
    }

    // MARK: Draw order

    /// A polygon absent from `[_drawOrder]` is never drawn, and is reported as such.
    func testAPolygonMissingFromTheDrawOrderIsReported() {
        let source = TypSource.parse("""
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
            """)
        XCTAssertEqual(source.drawOrder.map(\.code), [0x16])
        XCTAssertEqual(source.polygonsMissingFromDrawOrder, [0x50])
    }

    // MARK: Against kmap's own TYP

    func testAWholeFileParsesIntoEverySectionItHolds() throws {
        let source = TypSource.parse(TypFixture.source)

        XCTAssertEqual(source.familyID, 6324)
        XCTAssertEqual(source.productID, 1)
        XCTAssertEqual(source.codePage, 1252)

        XCTAssertEqual(source.sections(.point).count, TypFixture.pointCount)
        XCTAssertEqual(source.sections(.line).count, TypFixture.lineCount)
        XCTAssertEqual(source.sections(.polygon).count, TypFixture.polygonCount)

        XCTAssertEqual(source.polygonsMissingFromDrawOrder, [],
                       "a styled polygon absent from [_drawOrder] is never drawn")

        // Language 0x00 is the fallback where the device's own language has no entry.
        let unlabelled = source.sections.filter { $0.englishLabel == nil }
        XCTAssertEqual(unlabelled.map(\.hex), [], "sections with no English fallback label")
    }

    /// Every picture agrees with its own header: a short palette or too few rows leaves
    /// pixels resolving against absent colours.
    func testEveryPictureAgreesWithItsHeader() {
        let source = TypSource.parse(TypFixture.source)
        for section in source.sections {
            guard let picture = section.picture else { continue }
            XCTAssertEqual(picture.palette.count, picture.declaredColours,
                           "\(section.kind) \(section.hex): palette size")
            XCTAssertEqual(picture.rows.count, picture.height,
                           "\(section.kind) \(section.hex): row count")
            let grid = picture.pixels()
            XCTAssertEqual(grid?.count, picture.height, "\(section.kind) \(section.hex)")
            XCTAssertEqual(grid?.first?.count, picture.width, "\(section.kind) \(section.hex)")
        }
    }

    func testAFullSizeBadgeReadsBackAsATwentySquare() throws {
        let source = TypSource.parse(TypFixture.source)
        let section = try XCTUnwrap(source.section(.point, TypFixture.iconCode))
        XCTAssertEqual(section.englishLabel, "Restaurant")
        XCTAssertEqual(section.russianLabel, "Ресторан")

        let picture = try XCTUnwrap(section.picture)
        XCTAssertEqual(picture.width, TypFixture.iconWidth)
        XCTAssertEqual(picture.height, TypFixture.iconWidth)
        XCTAssertEqual(picture.declaredColours, TypFixture.iconColours)

        let grid = try XCTUnwrap(picture.pixels())
        XCTAssertEqual(grid.count, TypFixture.iconWidth)
        XCTAssertTrue(grid.allSatisfy { $0.count == TypFixture.iconWidth })
        // The badge is bordered, so the corner is a colour rather than transparent.
        XCTAssertNotNil(grid[0][0])
        // Its palette uses a semicolon as a key, which is not a comment marker here.
        XCTAssertEqual(picture.palette.count, TypFixture.iconColours)
    }

    // MARK: Whatever TYP this machine happens to have

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
                XCTAssertEqual(picture.palette.count, picture.declaredColours,
                               "\(url.lastPathComponent) \(section.hex)")
                XCTAssertEqual(picture.rows.count, picture.height,
                               "\(url.lastPathComponent) \(section.hex)")
            }
        }
    }

    // MARK: A pattern with nothing in it

    /// A pattern whose every pixel is transparent is reported as blank, though the element
    /// still names a colour. The pattern itself round-trips byte for byte.
    func testAPatternWithNothingVisibleInItSaysSo() throws {
        let source = TypSource.parse("""
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
        """)

        let blank = try XCTUnwrap(source.section(.line, 0x01))
        XCTAssertNotNil(blank.picture, "the pattern is there; it is its pixels that are not")
        XCTAssertTrue(blank.patternIsBlank)
        XCTAssertEqual(blank.colours.first ?? nil, "#809BC0",
                       "the one colour it names is what a device can draw it in")

        let dashed = try XCTUnwrap(source.section(.line, 0x02))
        XCTAssertFalse(dashed.patternIsBlank)
    }

    func testASectionWithNoPictureAtAllIsNotCalledBlank() {
        // A solid line has no pattern at all, which is not the same as a blank one.
        let source = TypSource.parse("""
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
        """)
        XCTAssertEqual(source.section(.line, 0x03)?.patternIsBlank, false)
    }

    // MARK: Line endings

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
        XCTAssertEqual(b.section(.point, 0x2a00)?.englishLabel,
                       a.section(.point, 0x2a00)?.englishLabel)
    }

    func testTheHeaderNumbersSurviveWindowsLineEndingsToo() {
        // A trailing carriage return makes the value unparseable as a number, leaving the
        // family id nil.
        let source = TypSource.parse("[_id]\r\nFID=1540\r\nProductCode=25\r\nCodePage=1251\r\n[end]\r\n")
        XCTAssertEqual(source.familyID, 1540)
        XCTAssertEqual(source.productID, 25)
        XCTAssertEqual(source.codePage, 1251)
    }

    /// Label keys carry a trailing language ordinal. Any number on the tail names the same
    /// key; the number is not part of it.
    func testNumberedLabelKeysAreLabelsWhateverTheNumber() {
        let source = TypSource.parse("""
            [_point]
            Type=0x2a00
            String1=0x00,One
            String2=0x04,Two
            String5=0x19,Пять
            String12=0x02,Twelve
            [end]
            """)
        let section = source.section(.point, 0x2a00)
        XCTAssertEqual(section?.labels.map(\.text), ["One", "Two", "Пять", "Twelve"])
        XCTAssertEqual(section?.englishLabel, "One")
    }
}
