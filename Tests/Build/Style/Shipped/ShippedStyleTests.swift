import XCTest

@testable import kmap

/// The shipped-style palette: the table parses, and the TYP written from it is one the
/// mkgmap compiler recognises section for section.
final class ShippedStyleTests: XCTestCase {
    /// The repository, found from this file rather than from the test runner's working
    /// directory, and by its Package.swift rather than by counting folders: the test has
    /// moved deeper once already.
    private var repository: URL {
        var directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        while directory.path != "/",
            !FileManager.default.fileExists(
                atPath: directory.appendingPathComponent("Package.swift").path
            )
        {
            directory = directory.deletingLastPathComponent()
        }
        return directory
    }

    private var cartoPalette: URL { paletteFile(of: "osm-carto") }

    /// The rule set a build of this code materializes, where the machine has mkgmap.
    private func index() throws -> RuleSetIndex {
        let directory = try RealBaseStyle.preparedDirectory()
        return try XCTUnwrap(RuleSetIndex.read(styleDirectory: directory))
    }

    /// Where a shipped style's table lives in the repository.
    private func paletteFile(of id: String) -> URL {
        repository.appendingPathComponent("Assets/styles/\(id)/palette.txt")
    }

    func testTheCartoTableParsesWhole() throws {
        let palette = try StylePalette.read(
            String(contentsOf: cartoPalette, encoding: .utf8)
        )
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
            String(contentsOf: cartoPalette, encoding: .utf8)
        )
        let text = TypGenerator.text(from: palette, fid: 6325)
        XCTAssertTrue(
            text.hasPrefix("; -*- coding: UTF-8 -*-"),
            "the coding line must stay on line 1"
        )
        XCTAssertTrue(text.contains("FID=6325"))
        XCTAssertEqual(
            text.components(separatedBy: "[_polygon]").count - 1,
            palette.polygons.count
        )
        XCTAssertEqual(
            text.components(separatedBy: "[_line]").count - 1,
            palette.lines.count
        )
        // Every polygon is in the draw order; one that is not is not drawn at all.
        let order = text.components(separatedBy: "[_drawOrder]")[1]
            .components(separatedBy: "[end]")[0]
        for poly in palette.polygons {
            XCTAssertTrue(
                order.contains(String(format: "Type=0x%03x,", poly.code)),
                "0x\(String(poly.code, radix: 16)) missing from [_drawOrder]"
            )
        }
        // Sections balance: every opener has its [end].
        XCTAssertEqual(
            text.components(separatedBy: "[end]").count - 1,
            palette.polygons.count + palette.lines.count + 2
        )
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
        XCTAssertEqual(
            points.components(separatedBy: "DayXpm=").count,
            points.components(separatedBy: "NightXpm=").count
        )
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
                    XCTAssertEqual(
                        types.count,
                        1,
                        "\(shipped.id) \(what): a section names \(types.count) types"
                    )
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
            XCTAssertGreaterThan(
                text.components(separatedBy: "[_polygon]").count,
                40,
                shipped.id
            )
        }
    }

    /// kmap's rules draw a roundabout on an extended overlay above 24 bits: a palette
    /// without those numbers leaves the main roads' roundabouts out on every coarser rung.
    func testEveryShippedPalettePaintsTheRoundaboutOverlays() throws {
        for shipped in StyleCatalog.shippedPalettes {
            let palette = try StylePalette.read(
                try String(contentsOf: paletteFile(of: shipped.id), encoding: .utf8)
            )
            let codes = Set(palette.lines.map(\.code))
            for code in 0x10801...0x10804 {
                XCTAssertTrue(codes.contains(code), "\(shipped.id) lacks line 0x\(String(code, radix: 16))")
            }
        }
    }

    /// The width is the whole stroke: below 3 pixels there is no room for a border either
    /// side, so the line is its casing colour alone rather than a 3-pixel road.
    func testANarrowCasedLineIsDrawnInItsCasingAlone() throws {
        let palette = try StylePalette.read(
            "line 0x0e 1 #ffffff #ababab  Path\nline 0x10 2 #ededed #bbbbbb  Living street\nline 0x06 3 #ffffff #bbbbbb  Minor road"
        )
        let text = TypGenerator.text(from: palette, fid: 6325)
        func section(_ code: String) -> String {
            text.components(separatedBy: "Type=\(code)\n")[1].components(separatedBy: "[end]")[0]
        }
        XCTAssertTrue(section("0x0e").contains("\"1 c #ababab\""))
        XCTAssertTrue(section("0x0e").contains("LineWidth=1"))
        XCTAssertFalse(section("0x0e").contains("BorderWidth"))
        XCTAssertTrue(section("0x10").contains("LineWidth=2"))
        XCTAssertFalse(section("0x10").contains("BorderWidth"))
        XCTAssertTrue(section("0x06").contains("LineWidth=1"))
        XCTAssertTrue(section("0x06").contains("BorderWidth=1"))
    }

    func testANoteAfterTheNameStaysOutOfIt() throws {
        let palette = try StylePalette.read(
            "poly 0x50 3 #77cc77  Forest  # filled, not theirs"
        )
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
                XCTAssertTrue(
                    [0, 85, 170, 255].contains(channel),
                    "\(day) → \(night): channel \(channel) is off the steps"
                )
            }
        }
        // Dimmed, not inverted: white must not come back white.
        XCTAssertNotEqual(TypGenerator.night(of: "#ffffff"), "#FFFFFF")
    }

    func testTheOpenTopoMapPatternsReplaceTheFlatColours() throws {
        let otm = try XCTUnwrap(StyleCatalog.shippedPalette(id: "opentopomap"))
        let text = try StyleCatalog.shippedTypText(of: otm)

        // A code with a pattern section keeps one section, the pattern, with no flat twin
        // beside it: mkgmap takes the last section for a code.
        for code in ["0x50", "0x4f", "0x1a", "0x04"] {
            let sections =
                text.components(separatedBy: "[_polygon]\nType=\(code)\n")
                .count - 1
            XCTAssertEqual(sections, 1, "polygon \(code) appears \(sections) times")
        }
        XCTAssertTrue(text.contains("Xpm=\"32 32 4 1\""), "the patterns ride in, with night colours")

        // The forest kinds carry their drawings on kmap's own codes, under the table's names.
        XCTAssertTrue(
            text.range(of: "Type=0x57\nString=0x00,Coniferous forest") != nil,
            "conifer pattern on 0x57, named from the table"
        )
        XCTAssertTrue(
            text.range(of: "Type=0x58\nString=0x00,Broadleaved forest") != nil,
            "broadleaf pattern on 0x58, named from the table"
        )
        XCTAssertFalse(text.contains("String=0x02,"), "no label of theirs names another meaning")

        XCTAssertTrue(text.contains("Type=0x14"), "the rail rides in")
        XCTAssertTrue(text.contains("Type=0x6619\nString=0x00,"), "the icons ride in, named")

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
        XCTAssertFalse(
            text.contains("Type=0x77"),
            "a polygon with no palette entry has no draw order — dropped"
        )
        XCTAssertTrue(text.contains("Type=0x14"), "an extra line section is appended")
    }

    /// A graphics block with CRLF line endings is read by the same section reader the TYP
    /// parser uses.
    func testGraphicsWithWindowsLineEndingsStillOverride() throws {
        let palette = try StylePalette.read("poly 0x50 3 #77cc77 Forest")
        let graphics = "[_polygon] ; forest\r\nType=0x50\r\nXpm=\"0 0 1 0\"\r\n\"a c #123456\"\r\n[end]\r\n"
        let text = TypGenerator.text(from: palette, fid: 1, graphics: graphics)
        XCTAssertTrue(text.contains("#123456"), "the pattern section replaced the flat one")
        XCTAssertFalse(text.contains("#77cc77"), "the flat twin is gone")
    }

    /// A note after the type makes it no number to mkgmap, which would refuse the whole
    /// TYP: such a section replaces nothing.
    func testAGraphicsSectionWithANoteAfterItsTypeReplacesNothing() throws {
        let palette = try StylePalette.read("poly 0x50 3 #77cc77 Forest")
        let graphics = "[_polygon]\nType=0x50 ; forest\nXpm=\"0 0 1 0\"\n\"a c #123456\"\n[end]\n"
        let text = TypGenerator.text(from: palette, fid: 1, graphics: graphics)
        XCTAssertFalse(text.contains("0x50 ; forest"))
        XCTAssertTrue(text.contains("#77cc77"))
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
                try String(contentsOf: paletteFile(of: shipped.id), encoding: .utf8)
            )
            for polygon in palette.polygons where polygon.code != 0x4b {
                XCTAssertNotNil(
                    rules.meaning(.polygon, polygon.code),
                    "\(shipped.id) paints polygon "
                        + String(format: "0x%02x", polygon.code)
                        + " (\(polygon.name)), which no rule of ours emits"
                )
            }
            for line in palette.lines {
                XCTAssertNotNil(
                    rules.meaning(.line, line.code),
                    "\(shipped.id) paints line "
                        + String(format: "0x%02x", line.code)
                        + " (\(line.name)), which no rule of ours emits"
                )
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
                try String(contentsOf: paletteFile(of: shipped.id), encoding: .utf8)
            )
            XCTAssertNil(palette.lines.first { $0.code == 0x0d }, shipped.id)
        }
    }

    /// Each transcribed look leaves the lines topoactive leaves to the device: the
    /// roads, their links and the widened numbers, which then fall back to the ones
    /// topoactive draws.
    func testTheTranscribedLooksLeaveTheDevicesLinesToTheDevice() throws {
        let deviceDrawn =
            [0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x08, 0x09, 0x0b, 0x0c, 0x0e, 0x0f, 0x10]
            + Array(0x31...0x35)
        for id in ["osm-carto", "cyclosm", "liberty-topo", "opentopomap"] {
            let shipped = try XCTUnwrap(StyleCatalog.shippedPalette(id: id))
            let typ = TypSource.parse(try StyleCatalog.shippedTypText(of: shipped))
            let lines = typ.codes(.line)
            for code in deviceDrawn {
                XCTAssertFalse(lines.contains(code), "\(id) draws line " + String(format: "0x%02x", code))
            }
            XCTAssertTrue(lines.contains(0x16), "\(id) draws the path")
        }
    }

    /// Every look's graphics are wired in: each of their sections is in the TYP once, with
    /// its own picture in place of the palette's flat colour.
    func testEveryShippedStyleCarriesItsGraphics() throws {
        for shipped in StyleCatalog.shippedPalettes {
            XCTAssertFalse(shipped.graphics.isEmpty, shipped.id)
            let typ = TypSource.parse(try StyleCatalog.shippedTypText(of: shipped))
            for section in TypSource.parse(shipped.graphics).sections {
                let label = "\(shipped.id) \(section.kind) " + String(format: "0x%02x", section.code)
                let found = typ.sections.filter { $0.kind == section.kind && $0.code == section.code }
                XCTAssertEqual(found.count, 1, label)
                let drawing = try XCTUnwrap(section.dayXpm ?? section.xpm, label)
                XCTAssertEqual(found.first.flatMap { $0.dayXpm ?? $0.xpm }, drawing, label)
            }
        }
    }

    /// The line widths of the transcribed looks are topoactive's, casing included; the path
    /// of carto, OpenTopoMap and Liberty Topo is 2 px, as 1 px of their ink was too faint
    /// on a device.
    func testTheTranscribedLooksDrawTopoactivesLineWidths() throws {
        let widths: [Int: Int] = [
            0x07: 3, 0x0a: 2, 0x11: 2, 0x16: 1, 0x18: 1, 0x1f: 2, 0x27: 6,
            0x10801: 8, 0x10802: 7, 0x10803: 7, 0x10804: 6
        ]
        for id in ["osm-carto", "cyclosm", "liberty-topo", "opentopomap"] {
            let shipped = try XCTUnwrap(StyleCatalog.shippedPalette(id: id))
            let typ = TypSource.parse(try StyleCatalog.shippedTypText(of: shipped))
            for (code, topoactive) in widths {
                let width = code == 0x16 && ["osm-carto", "opentopomap", "liberty-topo"].contains(id) ? 2 : topoactive
                let section = try XCTUnwrap(typ.sections.first { $0.kind == .line && $0.code == code })
                let lines = section.lines.map { typ.lines[$0] }
                func value(_ key: String) -> Int? {
                    lines.first { TypSource.sets(key, $0) }.flatMap { TypSource.entry(of: $0) }.flatMap {
                        Int($0.value)
                    }
                }
                let drawn = value("LineWidth").map { $0 + 2 * (value("BorderWidth") ?? 0) } ?? section.picture?.height
                XCTAssertEqual(drawn, width, "\(id) line " + String(format: "0x%02x", code))
            }
        }
    }

    /// What an original does not draw is a clear area, so the ground beneath shows.
    func testAnAreaTheOriginalDoesNotDrawIsClear() throws {
        let liberty = try XCTUnwrap(StyleCatalog.shippedPalette(id: "liberty-topo"))
        let typ = TypSource.parse(try StyleCatalog.shippedTypText(of: liberty))
        let residential = try XCTUnwrap(typ.sections.first { $0.kind == .polygon && $0.code == 0x10 })
        XCTAssertTrue(residential.patternIsBlank)
    }

    /// What an original does not draw shows nothing at all: a clear area carries no label.
    /// A clear line says its font outright: none, or the name the original writes along a
    /// line it does not draw (a valley in the OpenTopoMap web look).
    func testEveryClearSectionSaysWhetherItIsLabelled() throws {
        for shipped in StyleCatalog.shippedPalettes {
            let typ = TypSource.parse(try StyleCatalog.shippedTypText(of: shipped))
            for section in typ.sections where section.patternIsBlank {
                let label = "\(shipped.id) \(section.kind) " + String(format: "0x%02x", section.code)
                let style = try XCTUnwrap(section.fontStyle, label)
                if section.kind != .line {
                    XCTAssertTrue(style.lowercased().hasPrefix("nolabel"), label)
                }
            }
        }
    }

    /// A point the table names has a section in every look: one without a section shows the
    /// device's own icon for its number, which can mean something else (a temple on every
    /// tourist attraction). The original's symbol, or the anchor square where it has none.
    func testEveryNamedPointHasASectionInEveryLook() throws {
        let marks = Set(TypAugment.repairTypes.map { TypeNames.key($0.kind, $0.code) })
        let named = TypeNames.all.keys.filter {
            $0.hasPrefix(MapElementKind.point.rawValue + " ") && !marks.contains($0)
        }
        XCTAssertFalse(named.isEmpty)
        for shipped in StyleCatalog.shippedPalettes {
            let typ = TypSource.parse(try StyleCatalog.shippedTypText(of: shipped))
            let drawn = Set(typ.sections.filter { $0.kind == .point }.map { TypeNames.key(.point, $0.code) })
            for key in named.sorted() {
                XCTAssertTrue(drawn.contains(key), "\(shipped.id) has no section for \(key)")
            }
        }
    }

    /// The repair link and its mark are kmap's own: a style that drew either number would
    /// send the build's mark off to another one.
    func testNoShippedStyleDrawsTheRepairMarks() throws {
        for shipped in StyleCatalog.shippedPalettes {
            let typ = TypSource.parse(try StyleCatalog.shippedTypText(of: shipped))
            for mark in TypAugment.repairTypes {
                XCTAssertNil(typ.section(mark.kind, mark.code), "\(shipped.id) draws \(mark.what)")
            }
        }
    }

    /// Every look's night land is one grey: an icon whose night ink is that grey is not
    /// there at night.
    func testNoIconVanishesIntoTheNightLand() throws {
        for shipped in StyleCatalog.shippedPalettes {
            let typ = TypSource.parse(try StyleCatalog.shippedTypText(of: shipped))
            let land = try XCTUnwrap(typ.section(.polygon, 0x27)?.xpm?.colours.last ?? nil, shipped.id)
            for section in typ.sections where section.kind == .point {
                guard let ink = section.nightXpm?.dominantColour else { continue }
                XCTAssertNotEqual(
                    ink.uppercased(),
                    land.uppercased(),
                    "\(shipped.id) point 0x\(String(section.code, radix: 16)) is drawn in the night land's colour"
                )
            }
        }
    }

    /// A new profile starts with the shipped carto look, not the device's own drawing.
    func testANewProfileStartsWithCarto() {
        XCTAssertEqual(Settings.default.defaultStyleID, "osm-carto")
        XCTAssertNotNil(StyleCatalog.shippedPalette(id: Settings.default.defaultStyleID))
    }

    /// The cache hands out the same text for the same inputs, and other inputs under the
    /// same id are made afresh, never answered from it.
    func testTheShippedTypCacheAnswersOnlyTheSameInputs() throws {
        let carto = try XCTUnwrap(StyleCatalog.shippedPalette(id: "osm-carto"))
        let first = try StyleCatalog.shippedTypText(of: carto)
        XCTAssertEqual(try StyleCatalog.shippedTypText(of: carto), first)

        let other = StyleCatalog.ShippedPalette(
            id: carto.id,
            name: carto.name,
            summary: carto.summary,
            fid: carto.fid,
            palette: "name Other\npoly 0x4b 1 #000000  Background",
            points: "",
            graphics: ""
        )
        let changed = try StyleCatalog.shippedTypText(of: other)
        XCTAssertNotEqual(changed, first)
        XCTAssertEqual(try StyleCatalog.shippedTypText(of: carto), first, "the real one is made again")
    }

    /// kmap lays a floor under every wood (0x59) and scrub (0x5b), with the same outline.
    /// Of 2 shapes with the same outline on 1 level, which lands on top is chance, and a
    /// floor on top hides its pattern: each floor sits a level under, as in topoactive.
    func testEveryFloorSitsUnderItsPatterns() throws {
        let floors: [(floor: Int, over: [Int])] = [(0x59, [0x50, 0x57, 0x58]), (0x5b, [0x4f])]
        for shipped in StyleCatalog.shippedPalettes {
            let palette = try StylePalette.read(shipped.palette)
            let level = Dictionary(palette.polygons.map { ($0.code, $0.level) }, uniquingKeysWith: { a, _ in a })
            for (floor, over) in floors {
                guard let under = level[floor] else { continue }
                for code in over {
                    guard let above = level[code] else { continue }
                    XCTAssertLessThan(
                        under,
                        above,
                        "\(shipped.id) " + String(format: "0x%02x under 0x%02x", floor, code)
                    )
                }
            }
        }
    }

    /// A build lays the woods over the settlement tints, right above the highest open
    /// cover. What a look draws over its woods (a quarry, a cemetery, bare rock) stays over
    /// them after that, or a build would bury it under every wood.
    func testWhatALookDrawsOverItsWoodsStaysOverThemInABuild() throws {
        let woods = Set(TypAugment.woods)
        let moved = woods.union(TypAugment.groundTints).union(TypAugment.openCovers)
        for shipped in StyleCatalog.shippedPalettes {
            let text = try StyleCatalog.shippedTypText(of: shipped)
            let before = Dictionary(
                TypSource.parse(text).drawOrder.map { ($0.code, $0.level) },
                uniquingKeysWith: { a, _ in a }
            )
            var lines = text.components(separatedBy: "\n")
            _ = TypEdit.layWoodsOverTints(
                &lines,
                tints: TypAugment.groundTints,
                woods: TypAugment.woods,
                covers: TypAugment.openCovers
            )
            let after = Dictionary(
                TypSource.parse(lines.joined(separator: "\n")).drawOrder.map { ($0.code, $0.level) },
                uniquingKeysWith: { a, _ in a }
            )
            guard let woodsBefore = before.filter({ woods.contains($0.key) }).values.max(),
                let woodsAfter = after.filter({ woods.contains($0.key) }).values.max()
            else { continue }
            for (code, level) in before where level > woodsBefore && !moved.contains(code) {
                XCTAssertGreaterThan(
                    after[code] ?? 0,
                    woodsAfter,
                    "\(shipped.id) " + String(format: "0x%02x", code) + " goes under the woods in a build"
                )
            }
        }
    }

    /// What is drawn over the woods stays over them in a build in every look that draws
    /// it, whatever level it shares with the woods in the palette: what topoactive draws
    /// over its woods (rock, scree, a cemetery, a village green, a common, a park, a pitch),
    /// and a quarry and greenhouses, small patches the originals draw over a wood.
    func testWhatTopoactiveDrawsOverWoodsStaysOverThemInABuild() throws {
        let over = [0x54, 0x56, 0x0d, 0x1a, 0x15, 0x1d, 0x29, 0x17, 0x19]
        for shipped in StyleCatalog.shippedPalettes {
            let text = try StyleCatalog.shippedTypText(of: shipped)
            let drawn = Set(
                TypSource.parse(text).sections.filter { $0.kind == .polygon && !$0.patternIsBlank }.map(\.code)
            )
            var lines = text.components(separatedBy: "\n")
            _ = TypEdit.layWoodsOverTints(
                &lines,
                tints: TypAugment.groundTints,
                woods: TypAugment.woods,
                covers: TypAugment.openCovers
            )
            let after = Dictionary(
                TypSource.parse(lines.joined(separator: "\n")).drawOrder.map { ($0.code, $0.level) },
                uniquingKeysWith: { a, _ in a }
            )
            let woods = TypAugment.forest.compactMap { after[$0] }.max() ?? 0
            for code in over where drawn.contains(code) {
                XCTAssertGreaterThan(after[code] ?? 0, woods, "\(shipped.id) " + String(format: "0x%02x", code))
            }
        }
    }
}
