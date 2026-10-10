import XCTest

@testable import kmap

/// The names the generator writes into every section of a shipped TYP.
final class TypGeneratorTests: XCTestCase {
    private let names = TypeNames.parse(
        """
        polygon 0x13|Building|Здание
        line 0x16|Path|Тропа
        point 0x2a00|Restaurant|Ресторан
        point 0x6608|Tower|Башня
        """
    )

    private func palette(_ rows: String) throws -> StylePalette {
        try StylePalette.read("name Test\n" + rows)
    }

    func testAGeneratedSectionTakesTheTablesNamesOverThePalettes() throws {
        let text = TypGenerator.text(
            from: try palette("poly 0x13 1 #d9d0c9  Bldg\nline 0x16 2 #fa8072  Footway"),
            fid: 1,
            names: names
        )
        for wanted in ["String=0x00,Building", "String=0x19,Здание", "String=0x00,Path", "String=0x19,Тропа"] {
            XCTAssertTrue(text.contains(wanted), wanted)
        }
        XCTAssertFalse(text.contains("String=0x00,Bldg"))
    }

    func testACodeTheTableLacksKeepsThePalettesEnglishAndGetsNoRussian() throws {
        let text = TypGenerator.text(from: try palette("line 0x17 2 #bbbbbb  Breakwater"), fid: 1, names: names)
        XCTAssertTrue(text.contains("String=0x00,Breakwater"))
        XCTAssertFalse(text.contains("String=0x19"))
    }

    /// A borrowed drawing's own labels name its meaning in its own style: the table's
    /// English and Russian replace them, after its type.
    func testABorrowedSectionTakesTheTablesNamesInPlaceOfItsOwn() throws {
        let graphics = "[_line]\nType=0x16\nString=0x02,Fussweg\nXpm=\"0 0 1 0\"\n\"1 c #000000\"\n[end]"
        let text = TypGenerator.text(
            from: try palette("line 0x16 2 #fa8072  Footway"),
            fid: 1,
            graphics: graphics,
            names: names
        )
        let lines = text.components(separatedBy: "\n")
        let type = try XCTUnwrap(lines.firstIndex(of: "Type=0x16"))
        XCTAssertEqual(Array(lines[type + 1...type + 2]), ["String=0x00,Path", "String=0x19,Тропа"])
        XCTAssertFalse(text.contains("Fussweg"))
    }

    func testABorrowedSectionTheTableLacksKeepsItsLabelsAndGainsEnglish() throws {
        let graphics = "[_line]\nType=0x17\nString=0x02,Zaun\n[end]"
        let text = TypGenerator.text(
            from: try palette("line 0x17 2 #bbbbbb  Barrier"),
            fid: 1,
            graphics: graphics,
            names: names
        )
        XCTAssertTrue(text.contains("Type=0x17\nString=0x00,Barrier\nString=0x02,Zaun"))
    }

    /// A line the palette lacks is appended from the graphics, named from the table.
    func testAnAppendedLineSectionIsNamedFromTheTable() throws {
        let graphics = "[_line]\nType=0x16\nXpm=\"0 0 1 0\"\n\"1 c #000000\"\n[end]"
        let text = TypGenerator.text(from: try palette(""), fid: 1, graphics: graphics, names: names)
        XCTAssertTrue(text.contains("Type=0x16\nString=0x00,Path\nString=0x19,Тропа"))
    }

    /// A Russian label of the section's own is kept where the table has no name to give.
    func testARussianLabelIsKeptWhereTheTableLacksTheCode() throws {
        let graphics = "[_line]\nType=0x17\nString=0x19,Забор\n[end]"
        let text = TypGenerator.text(
            from: try palette("line 0x17 2 #bbbbbb  Barrier"),
            fid: 1,
            graphics: graphics,
            names: names
        )
        XCTAssertTrue(text.contains("String=0x19,Забор"))
        XCTAssertTrue(text.contains("String=0x00,Barrier"))
    }

    /// An icon written as a short type and a subtype is named by both, as mkgmap reads them.
    func testAnIconWithAShortTypeAndASubtypeIsNamed() throws {
        let points = "[_point]\nType=0x2a\nSubType=0x00\nDayXpm=\"1 1 1 1\"\n\"a c #000000\"\n\"a\"\n[end]"
        let text = TypGenerator.text(from: try palette(""), fid: 1, points: points, names: names)
        XCTAssertTrue(text.contains("SubType=0x00\nString=0x00,Restaurant\nString=0x19,Ресторан"))
    }

    /// Icons come with no names; each gets the table's, by its type and subtype.
    func testEveryIconIsNamedByItsCode() throws {
        let points = """
            [_point]
            Type=0x2a00
            DayXpm="1 1 1 1"
            "a c #000000"
            "a"
            [end]

            [_point]
            Type=0x66
            SubType=0x08
            DayXpm="1 1 1 1"
            "a c #000000"
            "a"
            [end]
            """
        let text = TypGenerator.text(from: try palette(""), fid: 1, points: points, names: names)
        XCTAssertTrue(text.contains("Type=0x2a00\nString=0x00,Restaurant\nString=0x19,Ресторан"))
        XCTAssertTrue(text.contains("SubType=0x08\nString=0x00,Tower\nString=0x19,Башня"))
    }
}
