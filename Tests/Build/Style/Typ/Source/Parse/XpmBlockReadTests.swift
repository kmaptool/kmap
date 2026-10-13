import XCTest

@testable import kmap

/// A picture read from a TYP source: header, palette and rows, as mkgmap reads them.
final class XpmBlockReadTests: XCTestCase {
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

    /// mkgmap reads 8 of a longer run of hex digits, and lays the alpha on them.
    func testALongColourIsReadByItsFirst8Digits() {
        let source = TypSource.parse("[_polygon]\nType=0x01\nXpm=\"0 0 1 0\"\n\"a c #00FF00FF00\" alpha=8\n[end]")
        XCTAssertEqual(source.section(.polygon, 0x01)?.colours, ["#00FF0077"])
    }
}
