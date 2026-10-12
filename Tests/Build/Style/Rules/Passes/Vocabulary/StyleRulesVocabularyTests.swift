import XCTest

@testable import kmap

/// A meaning moved onto a number of its own keeps the number it drew on before where the
/// palette paints no picture for the new one.
final class StyleRulesVocabularyTests: XCTestCase {
    /// A rule directory with the 3 files, thrown away afterwards.
    private func directory(
        points: String = "",
        lines: String = "",
        polygons: String = ""
    ) throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("palette-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        for (name, text) in [
            ("points", points), ("lines", lines),
            ("polygons", polygons)
        ] where !text.isEmpty {
            try text.write(
                to: dir.appendingPathComponent(name),
                atomically: true,
                encoding: .utf8
            )
        }
        return dir
    }

    private func read(_ dir: URL, _ file: String) throws -> String {
        try String(contentsOf: dir.appendingPathComponent(file), encoding: .utf8)
    }

    /// A palette older than the split paints the orchard allotments used to be drawn
    /// as: the rule goes back to that number rather than going quiet.
    func testAWidenedRuleGoesBackToTheNumberThePaletteCanPaint() throws {
        let dir = try directory(polygons: "landuse=allotments [0x5a resolution 21]\n")
        let orchard = TypSource.parse(
            """
            ; -*- coding: UTF-8 -*-
            [_polygon]
            Type=0x4e
            Xpm="0 0 1 0"
            "! c #F89800"
            [end]
            """
        )
        let moved = try StyleCatalog.keepTheOldNumberWherePaletteIsSilent(
            in: dir,
            palette: orchard,
            log: Log()
        )
        XCTAssertEqual(moved, 1)
        XCTAssertTrue(try read(dir, "polygons").contains("landuse=allotments [0x4e resolution 21]"))
    }

    /// A grade a palette does not paint goes to the via ferrata's number, and stays there
    /// where that is unpainted too: the build draws it as a path, never as a cliff.
    func testAGradeFallsBackAlongTheChain() throws {
        let dir = try directory(
            lines: """
                highway=via_ferrata & via_ferrata_scale ~ '3[+-]?' [0x3a resolution 22]
                highway=via_ferrata [0x37 resolution 22]
                """
        )
        let cliffOnly = TypSource.parse(
            """
            [_line]
            Type=0x2b
            Xpm="0 0 1 0"
            "! c #5A4632"
            [end]
            """
        )
        try StyleCatalog.keepTheOldNumberWherePaletteIsSilent(in: dir, palette: cliffOnly, log: Log())
        let lines = try read(dir, "lines")
        XCTAssertFalse(lines.contains("[0x2b"), lines)
        XCTAssertTrue(lines.contains("'3[+-]?' [0x37 resolution 22]"), lines)
    }

    /// Where the palette paints the new number, nothing moves.
    func testAPaletteThatPaintsTheNewNumberIsLeftAlone() throws {
        let dir = try directory(polygons: "landuse=allotments [0x5a resolution 21]\n")
        let dachas = TypSource.parse(
            """
            ; -*- coding: UTF-8 -*-
            [_polygon]
            Type=0x5a
            Xpm="0 0 1 0"
            "! c #E9D8BD"
            [end]
            """
        )
        let moved = try StyleCatalog.keepTheOldNumberWherePaletteIsSilent(
            in: dir,
            palette: dachas,
            log: Log()
        )
        XCTAssertEqual(moved, 0)
        XCTAssertTrue(try read(dir, "polygons").contains("[0x5a resolution 21]"))
    }

    /// A layer that never existed before has no number to go back to: it goes.
    func testTheOutlineLayerHasNoOlderNumberToFallBackOn() throws {
        let dir = try directory(
            lines: """
                building=* & building!=no [0x2f resolution 24 continue]
                highway=track [0x0a resolution 22]
                """
        )
        let withALine = TypSource.parse(
            """
            ; -*- coding: UTF-8 -*-
            [_line]
            Type=0x0a
            Xpm="0 0 1 0"
            "! c #202020"
            [end]
            """
        )
        let moved = try StyleCatalog.keepTheOldNumberWherePaletteIsSilent(
            in: dir,
            palette: withALine,
            log: Log()
        )
        XCTAssertEqual(moved, 1)
        // Gone on its own, without waiting for the palette filter: a style kmap ships
        // keeps its unpainted numbers, and an outline is not one of them.
        XCTAssertFalse(try read(dir, "lines").contains("0x2f"))
        XCTAssertTrue(try read(dir, "lines").contains("highway=track [0x0a resolution 22]"))
    }
}
