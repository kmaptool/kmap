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
        let source = TypSource.parse(
            """
            [_polygon]
            Type=0x16
            Xpm="0 0 2 0"
            "a c #A0D070"
            "b c #204020"
            String=0x00,Nature reserve
            [end]
            """
        )
        let section = try XCTUnwrap(source.section(.polygon, 0x16))
        let xpm = try XCTUnwrap(section.xpm)
        XCTAssertTrue(xpm.isSolid)
        XCTAssertEqual(xpm.colours, ["#A0D070", "#204020"], "day then night")
        XCTAssertNil(section.picture, "a solid block has no picture to draw")
        XCTAssertEqual(section.englishLabel, "Nature reserve")
    }

    func testATransparentPaletteSlotIsReadAsTransparentRatherThanAsBlack() throws {
        // `none` is a transparent slot; read as a colour it would flood the polygon.
        let source = TypSource.parse(
            """
            [_line]
            Type=0x23
            Xpm="4 1 2 1"
            "! c #789400"
            ". c none"
            "!..!"
            [end]
            """
        )
        let picture = try XCTUnwrap(source.section(.line, 0x23)?.picture)
        XCTAssertEqual(picture.pixels()?.first ?? [], ["#789400", nil, nil, "#789400"])
    }

    /// A semicolon is a legal palette key. Treating `;` as a comment marker without checking
    /// quoting truncates the palette, leaving pixels resolving against absent colours.
    func testASemicolonPaletteKeyIsNotMistakenForAComment() throws {
        let source = TypSource.parse(
            """
            [_point]
            Type=0x2a00
            DayXpm="2 1 2 1"
            "; c #FF0000"
            "a c #00FF00"
            ";a"
            [end]
            """
        )
        let picture = try XCTUnwrap(source.section(.point, 0x2a00)?.picture)
        XCTAssertEqual(picture.palette.count, 2)
        XCTAssertEqual(picture.pixels()?.first ?? [], ["#FF0000", "#00FF00"])
    }

    func testACommentOutsideQuotesIsStillStripped() {
        let source = TypSource.parse("[_id]\nFID=6324 ; the family id\n[end]\n")
        XCTAssertEqual(source.familyID, 6324)
    }

    func testLabelsKeepTheirLanguageIndex() throws {
        let source = TypSource.parse(
            """
            [_point]
            Type=0x2a00
            String=0x00,Restaurant
            String=0x19,Ресторан
            [end]
            """
        )
        let section = try XCTUnwrap(source.section(.point, 0x2a00))
        XCTAssertEqual(section.englishLabel, "Restaurant")
        XCTAssertEqual(section.russianLabel, "Ресторан")
    }

    func testALabelContainingACommaKeepsIt() throws {
        let source = TypSource.parse(
            """
            [_point]
            Type=0x6511
            String=0x00,Spring, drinking
            [end]
            """
        )
        XCTAssertEqual(source.section(.point, 0x6511)?.englishLabel, "Spring, drinking")
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

    // MARK: Saying a gap is on purpose

    /// A `; kmap:unstyled` marker records types the file leaves to the device, so a coverage
    /// report does not flag them.
    func testAFileCanSayWhichTypesItLeavesToTheDeviceOnPurpose() {
        let source = TypSource.parse(
            """
            ; kmap:unstyled lines 0x01 0x02 0x03 — the road hierarchy, left to the device
            [_line]
            Type=0x16
            Xpm="0 0 1 0"
            "a c #303030"
            [end]
            """
        )
        XCTAssertEqual(source.deliberatelyUnstyled[.line], [0x01, 0x02, 0x03])
        XCTAssertNil(source.deliberatelyUnstyled[.polygon])
    }

    func testTheMarkerNamesItsKindTheWayTheInterfaceDoes() {
        XCTAssertEqual(
            TypSource.parse("; kmap:unstyled polygons 0x0a\n")
                .deliberatelyUnstyled[.polygon],
            [0x0a]
        )
        XCTAssertEqual(
            TypSource.parse("; kmap:unstyled point 0x2a00\n")
                .deliberatelyUnstyled[.point],
            [0x2a00]
        )
    }

    /// Markers for one kind union rather than replacing one another.
    func testSeveralMarkersForOneKindCombine() {
        let source = TypSource.parse(
            """
            ; kmap:unstyled lines 0x01 0x02 — motorway and trunk
            ; kmap:unstyled lines 0x0b 0x0c — the link roads
            """
        )
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

    // MARK: Against kmap's own TYP

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

    /// Every picture agrees with its own header: a short palette or too few rows leaves
    /// pixels resolving against absent colours.
    func testEveryPictureAgreesWithItsHeader() {
        let source = TypSource.parse(TypFixture.source)
        for section in source.sections {
            guard let picture = section.picture else { continue }
            XCTAssertEqual(
                picture.palette.count,
                picture.declaredColours,
                "\(section.kind) \(section.hex): palette size"
            )
            XCTAssertEqual(
                picture.rows.count,
                picture.height,
                "\(section.kind) \(section.hex): row count"
            )
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

    /// Label keys carry a trailing language ordinal. Any number on the tail names the same
    /// key; the number is not part of it.
    func testNumberedLabelKeysAreLabelsWhateverTheNumber() {
        let source = TypSource.parse(
            """
            [_point]
            Type=0x2a00
            String1=0x00,One
            String2=0x04,Two
            String5=0x19,Пять
            String12=0x02,Twelve
            [end]
            """
        )
        let section = source.section(.point, 0x2a00)
        XCTAssertEqual(section?.labels.map(\.text), ["One", "Two", "Пять", "Twelve"])
        XCTAssertEqual(section?.englishLabel, "One")
    }

    /// `[end]` is optional to mkgmap: the next header closes a block, and so does the end
    /// of the file. Read otherwise, 2 points would merge into 1.
    func testABlockWithoutItsEndStopsAtTheNextHeader() {
        let source = TypSource.parse(
            """
            [_point]
            Type=0x2f06
            [_point]
            Type=0x2f07
            [end]
            [_line]
            Type=0x05
            """
        )
        XCTAssertEqual(source.sections.map(\.code), [0x2f06, 0x2f07, 0x05])
        XCTAssertEqual(source.sections.map(\.lines), [0..<2, 2..<5, 5..<7])
    }

    /// A point's `Type=0x2f` is 0x2f00 to mkgmap, as `Type=0x2f` with `SubType=0x00` is.
    func testAPointWithAShortTypeIsItsCodeWithSubtypeNothing() {
        let source = TypSource.parse("[_point]\nType=0x2f\n[end]\n[_point]\nType=0x2a\nSubType=0x01\n[end]")
        XCTAssertEqual(source.sections.map(\.code), [0x2f00, 0x2a01])
    }

    /// TYPViewer saves in the code page the file names: read as mkgmap reads it.
    func testATextTYPIsReadInItsCodePageWhereItIsNotUTF8() {
        var bytes = Array("[_id]\nCodePage=1251\n[end]\n[_point]\nType=0x2f00\nString=0x04,".utf8)
        bytes += CodePage.encode("Родник", codePage: 1251) ?? []
        bytes += Array("\n[end]\n".utf8)
        let text = TypSource.decodeText(bytes)
        XCTAssertTrue(text.contains("Родник"))
        XCTAssertEqual(TypSource.decodeText([0xEF, 0xBB, 0xBF] + Array("Type=0x01".utf8)), "Type=0x01")
        // A coding line naming a code page decides before any CodePage line.
        let coded =
            Array("; -*- coding: cp1251 -*-\nCodePage=1252\nString=0x04,".utf8)
            + (CodePage.encode("Родник", codePage: 1251) ?? [])
        XCTAssertTrue(TypSource.decodeText(coded).contains("Родник"))
    }

    /// Written back as UTF-8, it says so first, or mkgmap reads it by its CodePage line.
    func testWrittenBackTheTextSaysItIsUTF8() {
        let plain = "[_id]\nCodePage=1251\n[end]"
        XCTAssertTrue(TypSource.declaringUTF8(plain).hasPrefix(TypSource.codingLine + "\n[_id]"))
        let already = TypSource.codingLine + "\n" + plain
        XCTAssertEqual(TypSource.declaringUTF8(already), already)
        let other = "; -*- coding: cp1251 -*-\r\n" + "[_id]\r\n[end]"
        XCTAssertEqual(TypSource.declaringUTF8(other), TypSource.codingLine + "\r\n[_id]\r\n[end]")
    }

    // MARK: Code pages kmap cannot read, and bytes a page leaves undefined

    func testAByteThePageLeavesUndefinedSpoilsOnlyItself() {
        // 0x98 has no character in cp1251; the Cyrillic around it is still Cyrillic.
        let bytes: [UInt8] = Array("CodePage=1251\nString=0x19,".utf8) + [0xCB, 0xE5, 0xF1, 0x98]
        let text = TypSource.decodeText(bytes)
        XCTAssertTrue(text.hasSuffix("Лес\u{98}"), text)
    }

    func testATextInAPageKmapCannotReadGoesBackByteForByte() {
        // cp1257, the Baltic page, which kmap has no table for.
        let bytes: [UInt8] =
            Array("[_id]\r\nCodePage=1257\r\n[end]\r\n[_polygon]\r\nType=0x01\r\nString=0x04,".utf8)
            + [0xC1, 0xE0, 0xEB, 0xF8] + Array("\r\n[end]\r\n".utf8)
        let read = TypSource.decoding(bytes)
        XCTAssertTrue(read.byteForByte)
        XCTAssertEqual([UInt8](TypSource.bytesToWrite(read.text, byteForByte: true)), bytes)
        XCTAssertEqual(
            [UInt8](TypSource.bytesToWrite(read.text, declaring: true, byteForByte: true)),
            bytes,
            "an import keeps it as it came"
        )
        // An addition keeps the rest in its bytes, and what the page cannot hold is `?`.
        let added = read.text + "String=0x19,\u{41B}\r\n"
        let written = [UInt8](TypSource.bytesToWrite(added, declaring: true, byteForByte: true))
        XCTAssertEqual(Array(written.prefix(bytes.count)), bytes)
        XCTAssertEqual(Array(written.suffix(3)), Array("?\r\n".utf8))
    }

    /// UTF-8 that names a page kmap cannot read was read as UTF-8, and is written so: kept
    /// in single bytes it would change, and mkgmap would read it by the page.
    func testUTF8NamingAnUntabledPageIsStillUTF8() {
        let bytes = Array("[_id]\nCodePage=1257\n[end]\nString=0x04,P\u{E4}rnu\n".utf8)
        let read = TypSource.decoding(bytes)
        XCTAssertFalse(read.byteForByte)
        let written = String(decoding: TypSource.bytesToWrite(read.text, byteForByte: read.byteForByte), as: UTF8.self)
        XCTAssertTrue(written.hasPrefix(TypSource.codingLine), written)
        XCTAssertTrue(written.contains("P\u{E4}rnu"))
    }

    /// A coding line naming a charset kmap has no table for keeps the file as it came.
    func testACharsetKmapCannotReadKeepsItsBytesAndItsLine() {
        let bytes: [UInt8] = Array("; -*- coding: koi8-r -*-\nString=0x19,".utf8) + [0xEC, 0xC5, 0xD3, 0x0A]
        let read = TypSource.decoding(bytes)
        XCTAssertTrue(read.byteForByte)
        XCTAssertEqual([UInt8](TypSource.bytesToWrite(read.text, declaring: true, byteForByte: true)), bytes)
    }

    func testATextKmapCanReadIsStillWrittenAsUTF8() {
        let read = TypSource.decoding(Array("CodePage=1251\nString=0x19,".utf8) + [0xCB, 0xE5, 0xF1])
        XCTAssertFalse(read.byteForByte)
        let written = String(decoding: TypSource.bytesToWrite(read.text), as: UTF8.self)
        XCTAssertTrue(written.contains("\u{41B}\u{435}\u{441}"))
        XCTAssertTrue(written.lowercased().contains("coding: utf-8"), written)
        // Said to be UTF-8 already: no page to keep.
        let said = Array("; -*- coding: utf-8 -*-\nCodePage=1257\nString=0x04,\u{E9}".utf8)
        XCTAssertFalse(TypSource.decoding(said).byteForByte)
        XCTAssertFalse(
            TypSource.decoding(Array("CodePage=1257\nString=0x04,plain".utf8)).byteForByte,
            "ASCII reads alike anywhere"
        )
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

    /// Numbers as mkgmap reads them, by `Integer.decode`: a bare one is decimal.
    func testNumbersAreReadAsMkgmapReadsThem() {
        XCTAssertEqual(TypSource.decodedInteger("0x2f"), 0x2f)
        XCTAssertEqual(TypSource.decodedInteger("47"), 47)
        XCTAssertEqual(TypSource.decodedInteger("#2F"), 0x2f)
        XCTAssertEqual(TypSource.decodedInteger("017"), 0o17)
        XCTAssertEqual(TypSource.decodedInteger("-3"), -3)
        XCTAssertNil(TypSource.decodedInteger("2f"))
        XCTAssertNil(TypSource.decodedInteger("--3"))
        XCTAssertNil(TypSource.decodedInteger(""))
        let source = TypSource.parse("[_id]\nCodePage=0x04E3\n[end]\n[_line]\nType=47\n[end]")
        XCTAssertEqual(source.codePage, 1251)
        XCTAssertEqual(source.sections.map(\.code), [0x2f])
        XCTAssertEqual(
            TypSource.decodeText(Array("CodePage=0x04E3\nString=0x19,".utf8) + [0xCB]),
            "CodePage=0x04E3\nString=0x19,\u{41B}"
        )
    }

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

    /// A CodePage line with a note behind it reads alike both ways: the text is decoded
    /// in the page the parse reports.
    func testACodePageWithANoteBehindItReadsAlikeBothWays() {
        var bytes = Array("[_id]\nCodePage=1251 ; cyrillic\n[end]\n[_point]\nType=0x2f\nString=0x00,".utf8)
        bytes += [0xE9]
        bytes += Array("\n[end]\n".utf8)
        let text = TypSource.decoding(bytes).text
        XCTAssertEqual(TypSource.parse(text).codePage, 1251)
        XCTAssertEqual(TypSource.parse(text).section(.point, 0x2f00)?.labels.first?.text, "\u{0439}")
    }

    /// mkgmap's charset probe takes the first `CodePage=` line for a charset: a note behind
    /// the number, or 0, fails it, unless a coding line came first.
    func testACodePageLineMkgmapCannotProbeIsKnown() {
        XCTAssertTrue(TypSource.codePageTripsMkgmap("[_id]\nCodePage=1252 ;western\n[end]"))
        XCTAssertTrue(TypSource.codePageTripsMkgmap("[_id]\nCodePage=0\n[end]"))
        XCTAssertFalse(TypSource.codePageTripsMkgmap("[_id]\nCodePage=1252\n[end]"))
        XCTAssertFalse(TypSource.codePageTripsMkgmap("; -*- coding: UTF-8 -*-\n[_id]\nCodePage=1252 ;western\n[end]"))
        XCTAssertFalse(TypSource.codePageTripsMkgmap("[_id]\nCodePage = 1252 ;western\n[end]"), "not the probe's line")
        XCTAssertTrue(TypSource.codePageTripsMkgmap("[_id]\nCodePage=01252\n[end]"), "octal to Java")
        XCTAssertTrue(
            TypSource.codePageTripsMkgmap("; -*- mode: typ; coding: utf-8 -*-\n[_id]\nCodePage=1252 ;x\n[end]"),
            "the probe knows only `-*- coding:`"
        )
        XCTAssertEqual(
            TypSource.plainCodePageLine("[_id]\nCodePage=1257 ; Baltic\n[end]"),
            "[_id]\nCodePage=1257\n[end]"
        )
        XCTAssertFalse(TypSource.codePageTripsMkgmap("[_id]\nCodePage=cp1251\n[end]"), "a name Java reads")
        for bad in ["cp65001", "cp+1251", "cp01251"] {
            XCTAssertTrue(TypSource.codePageTripsMkgmap("[_id]\nCodePage=\(bad)\n[end]"), bad)
        }
        XCTAssertTrue(TypSource.codePageTripsMkgmap("; -*- coding: utf-8-unix -*-\n[_id]\n[end]"))
        XCTAssertTrue(TypSource.codePageTripsMkgmap("; -*- coding: -*-\n[_id]\n[end]"), "an empty name")
        XCTAssertFalse(TypSource.codePageTripsMkgmap("; -*- coding: koi8-r -*-\n[_id]\n[end]"))
        XCTAssertTrue(
            TypSource.codePageTripsMkgmap("; -*- coding: utf-8\t-*-\n[_id]\nCodePage=1252 ;x\n[end]"),
            "the probe cuts its charset at a space only"
        )
    }

    /// `CodePage=cp1251` names the page as Java does, and the text is read in it.
    func testACodePageNamedAsJavaNamesItIsRead() {
        var bytes = Array("[_id]\nCodePage=cp1251\n[end]\n[_point]\nType=0x2f\nString=0x00,".utf8)
        bytes += [0xE9]
        bytes += Array("\n[end]\n".utf8)
        let text = TypSource.decoding(bytes).text
        XCTAssertEqual(TypSource.parse(text).section(.point, 0x2f00)?.labels.first?.text, "\u{0439}")
    }

    /// A tab after the coding name is a slip: the text is read by the name before it, and
    /// kmap's copy says UTF-8 plainly.
    func testACodingLineWithATabIsReadByItsName() {
        let bytes = Array("; -*- coding: utf-8\t-*-\n[_point]\nType=0x2f\nString=0x00,\u{0439}\n[end]\n".utf8)
        let decoded = TypSource.decoding(bytes)
        XCTAssertFalse(decoded.byteForByte)
        XCTAssertEqual(TypSource.parse(decoded.text).section(.point, 0x2f00)?.labels.first?.text, "\u{0439}")
        XCTAssertTrue(TypSource.declaringUTF8(decoded.text).hasPrefix(TypSource.codingLine + "\n[_point]"))
    }

    /// mkgmap takes the first coding line: a UTF-8 one under it changes nothing.
    func testTheFirstCodingLineIsTheOneMkgmapTakes() {
        let text = "; -*- coding: cp1251\t-*-\n; -*- coding: utf-8 -*-\n[_id]\n[end]"
        XCTAssertNotEqual(TypSource.declaringUTF8(text), text)
    }

    /// Emacs's forms of a charset name are read as meant: `utf-8;`, `utf-8-unix`, `latin-1`.
    func testEmacsCharsetNamesAreReadAsMeant() {
        for line in ["; -*- coding: utf-8; mode: text -*-", "; -*- coding: utf-8-unix -*-"] {
            let bytes = Array("\(line)\n[_point]\nType=0x2f\nString=0x00,\u{0439}\n[end]\n".utf8)
            let decoded = TypSource.decoding(bytes)
            XCTAssertFalse(decoded.byteForByte, line)
            XCTAssertEqual(TypSource.parse(decoded.text).section(.point, 0x2f00)?.labels.first?.text, "\u{0439}", line)
            XCTAssertTrue(TypSource.codePageTripsMkgmap(decoded.text), line)
        }
        XCTAssertFalse(TypSource.decoding(Array("; -*- coding: latin-1 -*-\n\u{00E9}".utf8)).byteForByte)
        XCTAssertEqual(TypSource.cleanCharset("-*-"), "", "no name at all")
    }

    /// A copy kept byte for byte says no UTF-8: its coding line is put as Java reads it,
    /// or taken out.
    func testACopysCodingLineIsMendedForMkgmap() {
        XCTAssertEqual(
            TypSource.mendedCodingLine("; -*- coding: koi8-r; mode: typ -*-\n[_id]\n[end]"),
            "; -*- coding: koi8-r -*-\n[_id]\n[end]"
        )
        XCTAssertEqual(
            TypSource.mendedCodingLine("; -*- coding: latin-2 -*-\n[_id]\n[end]"),
            "; -*- coding: iso-8859-2 -*-\n[_id]\n[end]",
            "Emacs's name as Java's"
        )
        XCTAssertEqual(
            TypSource.mendedCodingLine("; -*- coding: latin2 -*-\n[_id]\n[end]"),
            "; -*- coding: latin2 -*-\n[_id]\n[end]",
            "a name Java may read stays, as it would in the original"
        )
        XCTAssertEqual(TypSource.mendedCodingLine("; -*- coding: ;; -*-\n[_id]\n[end]"), "[_id]\n[end]", "no name")
        XCTAssertEqual(
            TypSource.mendedCodingLine("; -*- coding: cp1251 -*-\n[_id]\n[end]"),
            "; -*- coding: cp1251 -*-\n[_id]\n[end]"
        )
    }

    /// Java trims only control characters and the space: a no-break space before the name
    /// is in the name.
    func testANoBreakSpaceBeforeTheCodingNameIsInIt() {
        XCTAssertTrue(TypSource.codePageTripsMkgmap("; -*- coding:\u{00A0}utf-8 -*-\n[_id]\n[end]"))
    }

    /// A legal name Java may read passes, as it would in the original; names known not to
    /// be Java's trip; a name is trimmed at both ends, as Java trims it.
    func testCharsetNamesTripOnlyWhereJavaIsKnownToRefuseThem() {
        func trips(_ name: String) -> Bool {
            TypSource.codePageTripsMkgmap("; -*- coding: \(name) -*-\n[_id]\n[end]")
        }
        for good in ["koi8", "latin2", "windows-874", "gbk", "iso-8859-5"] { XCTAssertFalse(trips(good), good) }
        for bad in ["iso-8859-14", "latin-2", "utf-8-unix", "cp65001"] { XCTAssertTrue(trips(bad), bad) }
        XCTAssertFalse(TypSource.codePageTripsMkgmap("; -*- coding: koi8-r\t\n[_id]\n[end]"), "trimmed at the end")
    }

    /// mkgmap reads 8 of a longer run of hex digits, and lays the alpha on them.
    func testALongColourIsReadByItsFirst8Digits() {
        let source = TypSource.parse("[_polygon]\nType=0x01\nXpm=\"0 0 1 0\"\n\"a c #00FF00FF00\" alpha=8\n[end]")
        XCTAssertEqual(source.section(.polygon, 0x01)?.colours, ["#00FF0077"])
    }

    /// A name no Java reads even cleaned, over bytes that are UTF-8, is read as UTF-8; a
    /// name kmap can mend keeps its own charset, as short text in it may read as UTF-8.
    func testOnlyAnUnmendableNameOverUTF8IsReadAsUTF8() {
        func decoded(_ name: String, _ label: [UInt8]) -> (String?, Bool) {
            let bytes =
                Array("; -*- coding: \(name) -*-\n[_point]\nType=0x2f\nString=0x00,".utf8) + label
                + Array("\n[end]\n".utf8)
            let read = TypSource.decoding(bytes)
            return (TypSource.parse(read.text).section(.point, 0x2f00)?.labels.first?.text, read.byteForByte)
        }
        XCTAssertEqual(decoded("iso-8859-14", Array("\u{0141}\u{0105}ka".utf8)).0, "\u{0141}\u{0105}ka")
        XCTAssertTrue(decoded("latin-2", [0xC3, 0xA1]).1, "Latin-2 bytes, kept as they are")
        XCTAssertEqual(TypSource.cleanCharset("iso8859_16"), "iso-8859-16")
        XCTAssertEqual(TypSource.cleanCharset("latin-0"), "iso-8859-15")
        XCTAssertFalse(TypSource.codePageTripsMkgmap("; -*- coding: latin-9 -*-\n[_id]\n[end]"), "Java reads it")
    }

    /// The coding line in line 2 is read however long line 1 is.
    func testACodingLineAfterALongFirstLineIsRead() {
        let first = "; " + String(repeating: "x", count: 600) + "\n"
        let bytes =
            Array((first + "; -*- coding: cp1251 -*-\n[_point]\nType=0x2f\nString=0x00,").utf8) + [0xE9]
            + Array("\n[end]\n".utf8)
        XCTAssertEqual(
            TypSource.parse(TypSource.decoding(bytes).text).section(.point, 0x2f00)?.labels.first?.text,
            "\u{0439}"
        )
    }

    /// Headers with spaces inside, and subtypes of lines and polygons, as mkgmap reads them.
    func testHeadersWithSpacesAndSubtypesAreReadAsMkgmapReadsThem() {
        let text =
            "[ _polygon ]\nSubType=0x05\nType=0x01\nXpm=\"0 0 1 0\"\n\"1 c #FF0000\"\n[ end ]\n[_line]\nType=0x10f04\nSubType=0x05\nXpm=\"0 0 1 0\"\n\"1 c #FF0000\"\n[end]"
        let source = TypSource.parse(text)
        XCTAssertNotNil(source.section(.polygon, 0x105))
        XCTAssertNotNil(source.section(.line, 0x10f05))
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
