import XCTest

@testable import kmap

/// A section read entry by entry, the later line winning.
final class TypSectionReaderTests: XCTestCase {
    func testASectionIsReadEntryByEntry() throws {
        var reader = TypSection.Reader(kind: .point, leadingComments: ["; a fuel station"])
        reader.read([
            "Type=0x2f",
            "SubType=0x01",
            "String=0x04,Fuel",
            "DayXpm=\"1 1 1 1\"",
            "\"a c #FF0000\"",
            "\"a\""
        ])
        let section = try XCTUnwrap(reader.section(lines: 0..<8))
        XCTAssertEqual(section.code, 0x2f01)
        XCTAssertEqual(section.comments, ["; a fuel station"])
        XCTAssertEqual(section.labels.first?.text, "Fuel")
        XCTAssertEqual(section.dayXpm?.palette.first?.colour, "#FF0000")
    }

    func testASectionNamingNoTypeIsNone() {
        var reader = TypSection.Reader(kind: .line, leadingComments: [])
        reader.read(["LineWidth=2"])
        XCTAssertNil(reader.section(lines: 0..<2))
    }
}
