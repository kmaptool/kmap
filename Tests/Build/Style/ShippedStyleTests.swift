import XCTest
@testable import kmap

/// The shipped-style palette: the table parses, and the TYP written from it is one the
/// mkgmap compiler recognises section for section.
final class ShippedStyleTests: XCTestCase {

    /// The repository's carto palette, located from this file rather than from the working
    /// directory of the test runner.
    private var cartoPalette: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // the file
            .deletingLastPathComponent()   // Style
            .deletingLastPathComponent()   // Build
            .deletingLastPathComponent()   // Tests
            .appendingPathComponent("Assets/styles/osm-carto/palette.txt")
    }

    /// The rule set a build materialized on this machine, read where there is one.
    private func index() throws -> RuleSetIndex {
        let directory = ZoomRealStyle.directory
        try XCTSkipUnless(FileManager.default.fileExists(
            atPath: directory.appendingPathComponent("polygons").path),
            "no materialized style on this machine")
        return try XCTUnwrap(RuleSetIndex.read(styleDirectory: directory))
    }

    /// Where a shipped style's table lives in the repository.
    private func paletteFile(of id: String) -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Assets/styles/\(id)/palette.txt")
    }

    func testTheCartoTableParsesWhole() throws {
        let palette = try StylePalette.read(
            String(contentsOf: cartoPalette, encoding: .utf8))
        XCTAssertFalse(palette.name.isEmpty)
        XCTAssertGreaterThan(palette.polygons.count, 40, "the carto table styles the map's areas")
        XCTAssertGreaterThan(palette.lines.count, 25, "and its roads")
        // Codes never repeat within a kind: the second entry would silently win.
        XCTAssertEqual(Set(palette.polygons.map(\.code)).count, palette.polygons.count)
        XCTAssertEqual(Set(palette.lines.map(\.code)).count, palette.lines.count)
    }

    func testABrokenLineIsAnErrorNotAGap() {
        XCTAssertThrowsError(try StylePalette.read("poly 0x32 xx #aad3df Sea"))
        XCTAssertThrowsError(try StylePalette.read("poly 0x32 1 #aad3df"), "no name")
        XCTAssertThrowsError(try StylePalette.read("hexagon 0x32 1 #aad3df Sea"))
    }

    func testTheGeneratedTypHasEverySection() throws {
        let palette = try StylePalette.read(
            String(contentsOf: cartoPalette, encoding: .utf8))
        let text = TypGenerator.text(from: palette, fid: 6325)
        XCTAssertTrue(text.hasPrefix("; -*- coding: UTF-8 -*-"),
                      "the coding line must stay on line 1")
        XCTAssertTrue(text.contains("FID=6325"))
        XCTAssertEqual(text.components(separatedBy: "[_polygon]").count - 1,
                       palette.polygons.count)
        XCTAssertEqual(text.components(separatedBy: "[_line]").count - 1,
                       palette.lines.count)
        // Every polygon is in the draw order; one that is not is not drawn at all.
        let order = text.components(separatedBy: "[_drawOrder]")[1]
            .components(separatedBy: "[end]")[0]
        for poly in palette.polygons {
            XCTAssertTrue(order.contains(String(format: "Type=0x%03x,", poly.code)),
                          "0x\(String(poly.code, radix: 16)) missing from [_drawOrder]")
        }
        // Sections balance: every opener has its [end].
        XCTAssertEqual(text.components(separatedBy: "[end]").count - 1,
                       palette.polygons.count + palette.lines.count + 2)
    }

    func testTheIconSectionsAreWholeAndDistinct() {
        let points = StyleAssets.cartoPoints
        let sections = points.components(separatedBy: "[_point]").count - 1
        XCTAssertGreaterThan(sections, 20, "the carto style ships POI icons")
        XCTAssertEqual(points.components(separatedBy: "[end]").count - 1, sections)
        // One icon per code: the second section for a type would silently win.
        let types = points.components(separatedBy: "\n")
            .filter { $0.hasPrefix("Type=") }
        XCTAssertEqual(Set(types).count, sections)
        // Every section carries both a day and a night drawing.
        XCTAssertEqual(points.components(separatedBy: "DayXpm=").count,
                       points.components(separatedBy: "NightXpm=").count)
    }

    /// A section that names no type reaches the compiler as an empty block and mkgmap
    /// refuses the whole file — which is how a style whose source has its own sections
    /// commented out gets copied. Every section a style ships must name a type, once.
    func testEverySectionAShippedStyleShipsNamesItsTypeExactlyOnce() throws {
        for shipped in StyleCatalog.shippedPalettes {
            for (what, text) in [("points", shipped.points), ("graphics", shipped.graphics)]
            where !text.isEmpty {
                let blocks = text.components(separatedBy: "[end]").dropLast()
                    .filter { $0.contains("[_") }
                for block in blocks {
                    let types = block.components(separatedBy: "\n")
                        .filter { $0.trimmingCharacters(in: .whitespaces).hasPrefix("Type=") }
                    XCTAssertEqual(types.count, 1,
                                   "\(shipped.id) \(what): a section names \(types.count) types")
                }
            }
        }
    }

    func testTheIconsRideAlongInTheGeneratedTyp() throws {
        let carto = try XCTUnwrap(StyleCatalog.shippedPalette(id: "osm-carto"))
        let text = try StyleCatalog.shippedTypText(of: carto)
        XCTAssertTrue(text.contains("[_point]"))
        XCTAssertTrue(text.contains("String=0x00,Restaurant"))
    }

    func testEveryShippedPaletteGeneratesACompleteTyp() throws {
        // Distinct ids and family ids, and each table parses into a full TYP.
        let all = StyleCatalog.shippedPalettes
        XCTAssertEqual(Set(all.map(\.id)).count, all.count)
        XCTAssertEqual(Set(all.map(\.fid)).count, all.count)
        for shipped in all {
            let text = try StyleCatalog.shippedTypText(of: shipped)
            XCTAssertTrue(text.contains("FID=\(shipped.fid)"), shipped.id)
            XCTAssertTrue(text.contains("[_drawOrder]"), shipped.id)
            XCTAssertGreaterThan(text.components(separatedBy: "[_polygon]").count, 40,
                                 shipped.id)
        }
    }

    func testANoteAfterTheNameStaysOutOfIt() throws {
        let palette = try StylePalette.read(
            "poly 0x50 3 #77cc77  Forest  # filled, not theirs")
        XCTAssertEqual(palette.polygons.first?.name, "Forest")
    }

    func testNightColoursSitOnTheWatchSteps() {
        // A low-colour receiver display holds four levels per channel; values between them
        // are not reproduced.
        for day in ["#f2efe9", "#aad3df", "#e892a2", "#000000", "#ffffff"] {
            let night = TypGenerator.night(of: day)
            for at in [1, 3, 5] {
                let from = night.index(night.startIndex, offsetBy: at)
                let channel = Int(night[from...night.index(after: from)], radix: 16)!
                XCTAssertTrue([0, 85, 170, 255].contains(channel),
                              "\(day) → \(night): channel \(channel) is off the steps")
            }
        }
        // Dimmed, not inverted: white must not come back white.
        XCTAssertNotEqual(TypGenerator.night(of: "#ffffff"), "#FFFFFF")
    }

    func testTheOpenTopoMapGraphicsReplaceFlatColoursAndAddRail() throws {
        let otm = try XCTUnwrap(StyleCatalog.shippedPalette(id: "opentopomap"))
        let text = try StyleCatalog.shippedTypText(of: otm)

        // A code with a pattern section keeps one section, the pattern, with no flat twin
        // beside it: mkgmap takes the last section for a code.
        for code in ["0x50", "0x4f", "0x1a", "0x04"] {
            let sections = text.components(separatedBy: "[_polygon]\nType=\(code)\n")
                .count - 1
            XCTAssertEqual(sections, 1, "polygon \(code) appears \(sections) times")
        }
        XCTAssertTrue(text.contains("Xpm=\"32 32 2 1\""), "the patterns ride in whole")

        // The forest kinds carry the third-party style's drawings on kmap's own codes,
        // under the table's own name — theirs is in German, and the map is not.
        XCTAssertTrue(text.range(of: "Type=0x57\nString=0x00,Coniferous forest") != nil,
                      "conifer pattern renumbered onto 0x57, named from the table")
        XCTAssertTrue(text.contains("String=0x02,Nadelwald"), "their own label rides along")
        XCTAssertTrue(text.range(of: "Type=0x58\nString=0x00,Broadleaved forest") != nil,
                      "broadleaf pattern renumbered onto 0x58, named from the table")

        // Rail is not in the palette table at all: the line sections are appended.
        XCTAssertTrue(text.contains("Type=0x14"), "rail rides in")
        // The icons ride along as they do for the other shipped palettes.
        XCTAssertTrue(text.contains("[_point]"))
        XCTAssertTrue(text.contains("String=0x04,cave"))

        // Every section is closed: unbalanced [end]s are how a TYP refuses to compile.
        let opened = ["[_polygon]", "[_line]", "[_point]", "[_id]", "[_drawOrder]"]
            .map { text.components(separatedBy: $0).count - 1 }.reduce(0, +)
        XCTAssertEqual(text.components(separatedBy: "[end]").count - 1, opened)
    }

    func testAGraphicsSectionForACodeThePaletteLacksIsNotAPolygon() throws {
        let palette = try StylePalette.read("poly 0x50 3 #77cc77 Forest")
        let graphics = """
        [_polygon]
        Type=0x77
        Xpm="0 0 1 0"
        "a c #123456"
        [end]
        [_line]
        Type=0x14
        Xpm="0 0 1 0"
        "a c #123456"
        [end]
        """
        let text = TypGenerator.text(from: palette, fid: 1, graphics: graphics)
        XCTAssertFalse(text.contains("Type=0x77"),
                       "a polygon with no palette entry has no draw order — dropped")
        XCTAssertTrue(text.contains("Type=0x14"), "an extra line section is appended")
    }

    /// A graphics block with CRLF line endings is read by the same section reader the TYP
    /// parser uses.
    func testGraphicsWithWindowsLineEndingsStillOverride() throws {
        let palette = try StylePalette.read("poly 0x50 3 #77cc77 Forest")
        let graphics = "[_polygon]\r\nType=0x50 ; forest\r\nXpm=\"0 0 1 0\"\r\n\"a c #123456\"\r\n[end]\r\n"
        let text = TypGenerator.text(from: palette, fid: 1, graphics: graphics)
        XCTAssertTrue(text.contains("#123456"), "the pattern section replaced the flat one")
        XCTAssertFalse(text.contains("#77cc77"), "the flat twin is gone")
    }

    /// A palette kmap ships paints only numbers kmap's rules emit. The two meet through
    /// the number and nothing else, so a colour on a number no rule reaches is a colour
    /// nobody sees, and a number that has since changed hands wears the wrong one. The
    /// one exception is the background: no rule emits it because no shape carries it —
    /// the receiver paints it under everything, and a fenix goes black without it.
    func testEveryColourAShippedPaletteCarriesLandsOnARuleOfOurs() throws {
        let rules = try index()
        for shipped in StyleCatalog.shippedPalettes {
            let palette = try StylePalette.read(
                try String(contentsOf: paletteFile(of: shipped.id), encoding: .utf8))
            for polygon in palette.polygons where polygon.code != 0x4b {
                XCTAssertNotNil(rules.meaning(.polygon, polygon.code),
                                "\(shipped.id) paints polygon "
                                + String(format: "0x%02x", polygon.code)
                                + " (\(polygon.name)), which no rule of ours emits")
            }
            for line in palette.lines {
                XCTAssertNotNil(rules.meaning(.line, line.code),
                                "\(shipped.id) paints line "
                                + String(format: "0x%02x", line.code)
                                + " (\(line.name)), which no rule of ours emits")
            }
        }
    }

    /// kmap draws the link it puts in across a kerb or a bank on 0x0d, in red dashes of
    /// its own that the build adds to whatever TYP it compiles. A palette that paints
    /// that number replaces them with a flat stripe — and under any name but the build's
    /// it is taken for a foreign vocabulary and the link moves off 0x0d altogether. So a
    /// shipped palette leaves the number alone.
    func testNoShippedPalettePaintsOverTheRepairLink() throws {
        for shipped in StyleCatalog.shippedPalettes {
            let palette = try StylePalette.read(
                try String(contentsOf: paletteFile(of: shipped.id), encoding: .utf8))
            XCTAssertNil(palette.lines.first { $0.code == 0x0d }, shipped.id)
        }
    }
}
