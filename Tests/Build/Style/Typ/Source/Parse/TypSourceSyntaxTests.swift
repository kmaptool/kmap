import XCTest

@testable import kmap

/// A TYP source line as mkgmap reads it: headers, entries, numbers, labels and markers.
final class TypSourceSyntaxTests: XCTestCase {
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

    func testACommentOutsideQuotesIsStillStripped() {
        let source = TypSource.parse("[_id]\nFID=6324 ; the family id\n[end]\n")
        XCTAssertEqual(source.familyID, 6324)
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

    /// Headers with spaces inside, and subtypes of lines and polygons, as mkgmap reads them.
    func testHeadersWithSpacesAndSubtypesAreReadAsMkgmapReadsThem() {
        let text =
            "[ _polygon ]\nSubType=0x05\nType=0x01\nXpm=\"0 0 1 0\"\n\"1 c #FF0000\"\n[ end ]\n[_line]\nType=0x10f04\nSubType=0x05\nXpm=\"0 0 1 0\"\n\"1 c #FF0000\"\n[end]"
        let source = TypSource.parse(text)
        XCTAssertNotNil(source.section(.polygon, 0x105))
        XCTAssertNotNil(source.section(.line, 0x10f05))
    }
}
