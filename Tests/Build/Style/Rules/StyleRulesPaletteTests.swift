import XCTest
@testable import kmap

/// What a build does with rules the palette paints no picture for. The danger is not
/// the rule that goes quiet but the object that falls through and is drawn as something
/// else, so each test checks the rest of the chain too.
final class StyleRulesPaletteTests: XCTestCase {

    /// A rule directory with the three files, thrown away afterwards.
    private func directory(points: String = "", lines: String = "",
                           polygons: String = "") throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("palette-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        for (name, text) in [("points", points), ("lines", lines),
                             ("polygons", polygons)] where !text.isEmpty {
            try text.write(to: dir.appendingPathComponent(name), atomically: true,
                           encoding: .utf8)
        }
        return dir
    }

    private func read(_ dir: URL, _ file: String) throws -> String {
        try String(contentsOf: dir.appendingPathComponent(file), encoding: .utf8)
    }

    /// A palette painting one polygon and nothing else.
    private let palette = TypSource.parse("""
        ; -*- coding: UTF-8 -*-
        [_polygon]
        Type=0x50
        Xpm="0 0 1 0"
        "! c #60B020"
        [end]
        """)

    func testARuleThePaletteCannotPaintKeepsItsConditionAndLosesItsType() throws {
        let dir = try directory(polygons: """
            landuse=forest [0x50 resolution 20]
            landuse=quarry [0x0c resolution 20]
            """)
        _ = try StyleCatalog.keepOnlyWhatThePaletteDraws(in: dir, palette: palette,
                                                         log: Log())
        let out = try read(dir, "polygons")
        XCTAssertTrue(out.contains("landuse=forest [0x50 resolution 20]"))
        // Not deleted: an object that stops here cannot fall into the rules below and
        // be drawn as something else.
        XCTAssertTrue(out.contains("landuse=quarry {delete landuse}"))
        XCTAssertFalse(out.contains("[0x0c"))
    }

    /// A layer that does nothing but draw goes: the rule below still matches, and a
    /// `delete` there would take the object with it.
    func testAnUnpaintedContinueLayerIsRemovedOutright() throws {
        let dir = try directory(polygons: """
            landuse=forest [0x2f resolution 24 continue]
            landuse=forest [0x50 resolution 20]
            """)
        _ = try StyleCatalog.keepOnlyWhatThePaletteDraws(in: dir, palette: palette,
                                                         log: Log())
        let out = try read(dir, "polygons")
        XCTAssertFalse(out.contains("0x2f"))
        XCTAssertTrue(out.contains("landuse=forest [0x50 resolution 20]"))
    }

    /// The mark on a repair link is drawn by every build: its section is added to the
    /// TYP after this pass, so the rule must survive a palette that paints no 0x660b.
    func testTheRepairMarkIsNeverSilenced() throws {
        let dir = try directory(points: """
            kmap:repair=* [0x660b resolution 22]
            amenity=bench [0x6605 resolution 24]
            """)
        // A palette that paints one point, so the points file is looked at.
        let palette = TypSource.parse("""
            ; -*- coding: UTF-8 -*-
            [_point]
            Type=0x2c04
            DayXpm="1 1 1 1"
            "! c #000000"
            "!"
            [end]
            """)
        _ = try StyleCatalog.keepOnlyWhatThePaletteDraws(in: dir, palette: palette,
                                                         log: Log())
        let out = try read(dir, "points")
        XCTAssertTrue(out.contains("kmap:repair=* [0x660b resolution 22]"))
        XCTAssertTrue(out.contains("amenity=bench {delete amenity}"), "the bench still goes")
    }

    /// A town is drawn by the receiver itself, whatever the palette paints: silencing
    /// the place rules took every settlement label off a map.
    func testASettlementIsNeverSilenced() throws {
        let dir = try directory(points: """
            place=village & name=* [0x0c00 resolution 24]
            amenity=bench [0x6605 resolution 24]
            """)
        let palette = TypSource.parse("""
            ; -*- coding: UTF-8 -*-
            [_point]
            Type=0x2c04
            DayXpm="1 1 1 1"
            "! c #000000"
            "!"
            [end]
            """)
        _ = try StyleCatalog.keepOnlyWhatThePaletteDraws(in: dir, palette: palette,
                                                         log: Log())
        let out = try read(dir, "points")
        XCTAssertTrue(out.contains("place=village & name=* [0x0c00 resolution 24]"))
        XCTAssertTrue(out.contains("amenity=bench {delete amenity}"))
    }

    /// Silencing a road would take its routing, so `road_class` is left alone.
    func testARoutableRuleIsNeverSilenced() throws {
        let dir = try directory(lines: """
            highway=track [0x0a road_class=0 road_speed=1 resolution 22]
            """)
        _ = try StyleCatalog.keepOnlyWhatThePaletteDraws(in: dir, palette: palette,
                                                         log: Log())
        XCTAssertTrue(try read(dir, "lines").contains("[0x0a road_class=0"))
    }

    /// A number a person aimed a rule at by hand stays, painted or not.
    func testANumberChosenByHandIsSpared() throws {
        let rules = "landuse=quarry [0x0c resolution 20]\n"
        let bare = try directory(polygons: rules)
        _ = try StyleCatalog.keepOnlyWhatThePaletteDraws(in: bare, palette: palette,
                                                         log: Log())
        XCTAssertFalse(try read(bare, "polygons").contains("[0x0c"))

        let chosen = try directory(polygons: rules)
        _ = try StyleCatalog.keepOnlyWhatThePaletteDraws(in: chosen, palette: palette,
                                                         chosen: [.polygon: [0x0c]],
                                                         log: Log())
        XCTAssertTrue(try read(chosen, "polygons").contains("landuse=quarry [0x0c resolution 20]"))
    }

    /// The ground the map stands on answers to the build, not to a palette.
    func testTheBuildsOwnNumbersAreNotSilenced() throws {
        let dir = try directory(lines: "kmap=contour [0x21 resolution 20]\n",
                                polygons: "natural=sea [0x32 resolution 12]\n")
        _ = try StyleCatalog.keepOnlyWhatThePaletteDraws(in: dir, palette: palette,
                                                         log: Log())
        XCTAssertTrue(try read(dir, "lines").contains("[0x21"))
        XCTAssertTrue(try read(dir, "polygons").contains("[0x32"))
    }

    // MARK: The numbers the widening moved

    /// A palette older than the split paints the orchard allotments used to be drawn
    /// as: the rule goes back to that number rather than going quiet.
    func testAWidenedRuleGoesBackToTheNumberThePaletteCanPaint() throws {
        let dir = try directory(polygons: "landuse=allotments [0x5a resolution 21]\n")
        let orchard = TypSource.parse("""
            ; -*- coding: UTF-8 -*-
            [_polygon]
            Type=0x4e
            Xpm="0 0 1 0"
            "! c #F89800"
            [end]
            """)
        let moved = try StyleCatalog.keepTheOldNumberWherePaletteIsSilent(
            in: dir, palette: orchard, log: Log())
        XCTAssertEqual(moved, 1)
        XCTAssertTrue(try read(dir, "polygons").contains("landuse=allotments [0x4e resolution 21]"))
    }

    /// Where the palette paints the new number, nothing moves.
    func testAPaletteThatPaintsTheNewNumberIsLeftAlone() throws {
        let dir = try directory(polygons: "landuse=allotments [0x5a resolution 21]\n")
        let dachas = TypSource.parse("""
            ; -*- coding: UTF-8 -*-
            [_polygon]
            Type=0x5a
            Xpm="0 0 1 0"
            "! c #E9D8BD"
            [end]
            """)
        let moved = try StyleCatalog.keepTheOldNumberWherePaletteIsSilent(
            in: dir, palette: dachas, log: Log())
        XCTAssertEqual(moved, 0)
        XCTAssertTrue(try read(dir, "polygons").contains("[0x5a resolution 21]"))
    }

    /// A layer that never existed before has no number to go back to: it goes.
    func testTheOutlineLayerHasNoOlderNumberToFallBackOn() throws {
        let dir = try directory(lines: """
            building=* & building!=no [0x2f resolution 24 continue]
            highway=track [0x0a resolution 22]
            """)
        let withALine = TypSource.parse("""
            ; -*- coding: UTF-8 -*-
            [_line]
            Type=0x0a
            Xpm="0 0 1 0"
            "! c #202020"
            [end]
            """)
        let moved = try StyleCatalog.keepTheOldNumberWherePaletteIsSilent(
            in: dir, palette: withALine, log: Log())
        XCTAssertEqual(moved, 1)
        // Gone on its own, without waiting for the palette filter: a style kmap ships
        // keeps its unpainted numbers, and an outline is not one of them.
        XCTAssertFalse(try read(dir, "lines").contains("0x2f"))
        XCTAssertTrue(try read(dir, "lines").contains("highway=track [0x0a resolution 22]"))
    }

    /// A reserve gets its hatch because the layer above set a tag: silencing the layer
    /// must take its type and leave the actions.
    func testAnUnpaintedLayerKeepsTheActionsTheRulesBelowNeed() throws {
        let dir = try directory(polygons: """
            leisure=nature_reserve & kmap:zone_edge!=* {name '${name}'; set kmap:zone_edge=yes} [0x19 resolution 18 continue with_actions]
            kmap:zone_edge=yes [0x50 resolution 18]
            """)
        _ = try StyleCatalog.keepOnlyWhatThePaletteDraws(in: dir, palette: palette,
                                                         log: Log())
        let out = try read(dir, "polygons")
        XCTAssertFalse(out.contains("0x19"))
        XCTAssertTrue(out.contains("set kmap:zone_edge=yes}"))
        XCTAssertTrue(out.contains("kmap:zone_edge=yes [0x50 resolution 18]"))
    }
}
