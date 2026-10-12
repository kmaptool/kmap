import XCTest

@testable import kmap

/// A via ferrata routed as a path and drawn by its grade.
final class StyleRulesFerrataGradesTests: XCTestCase {
    private var directory: URL!
    private var catalog: StyleCatalog!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ferrata-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let settings = SettingsStore()
        catalog = StyleCatalog(settings: settings, toolchain: Toolchain(settings: settings))
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func write(_ text: String) throws {
        try text.write(to: directory.appendingPathComponent("lines"), atomically: true, encoding: .utf8)
    }

    private func read() throws -> String {
        try String(contentsOf: directory.appendingPathComponent("lines"), encoding: .utf8)
    }

    private let road =
        "{add foot=yes; add access=no; set vehicle=no; set bicycle=no; set motor_vehicle=no; set mkgmap:unpaved=1}"

    /// Each grade is a path's road, on foot only, then its own plain line, all above the
    /// via ferrata's own rule and on its rung; the ungraded road comes last.
    func testEachGradeIsARoadThenItsOwnLine() throws {
        try write("highway=via_ferrata [0x37 resolution 21]  # kmap: a note\nhighway=path [0x0e resolution 22]\n")
        try catalog.splitFerrataGrades(in: directory, log: Log())
        let lines = try read().components(separatedBy: "\n")
        XCTAssertEqual(
            lines[1],
            "highway=via_ferrata & via_ferrata_scale ~ '2[+-]?' & kmap:own_twin!=yes \(road)"
                + " [0x0e road_class=0 road_speed=0 resolution 21 continue]"
        )
        XCTAssertEqual(lines[2], "highway=via_ferrata & via_ferrata_scale ~ '2[+-]?' [0x39 resolution 21]")
        XCTAssertEqual(lines[10], "highway=via_ferrata & via_ferrata_scale ~ '6[+-]?' [0x3d resolution 21]")
        XCTAssertEqual(
            lines[11],
            "highway=via_ferrata & kmap:own_twin!=yes \(road) [0x0e road_class=0 road_speed=0 resolution 21 continue]"
        )
        XCTAssertEqual(lines[12], "highway=via_ferrata [0x37 resolution 21]  # kmap: a note")
        // Once: the marker says it is done.
        try catalog.splitFerrataGrades(in: directory, log: Log())
        XCTAssertEqual(try read().components(separatedBy: "[0x39").count, 2)
    }

    /// Where the TYP has no picture for a line, the line goes and its road is left a plain
    /// path road, for the road twins to draw as a path. A painted grade keeps its pair.
    func testAnUnpaintedLineGoesAndItsRoadIsTwinnedAsAPath() throws {
        // The via ferrata's own rule exactly as the redirects add it, note and all.
        let own = try XCTUnwrap(
            StyleAssets.iconRedirects.components(separatedBy: "\n")
                .first { $0.hasPrefix("+ highway=via_ferrata [0x37 ") }
        ).dropFirst(2)
        try write("highway=path [0x0e resolution 22]\n\(own)\n")
        try catalog.splitFerrataGrades(in: directory, log: Log())
        try StyleCatalog.drawFerrataAsPath(in: directory, painted: [0x3a])
        let text = try read()
        XCTAssertFalse(text.contains("[0x37"), text)
        XCTAssertTrue(
            text.contains("highway=via_ferrata \(road) [0x0e road_class=0 road_speed=0 resolution 22]\n"),
            text
        )
        XCTAssertTrue(text.contains("'3[+-]?' & kmap:own_twin!=yes"), text)
        XCTAssertTrue(text.contains("'3[+-]?' [0x3a resolution 22]"), text)
        XCTAssertFalse(text.contains("[0x39"), text)
    }

    /// After the twins: a via ferrata whose road was twinned keeps its line, one whose road
    /// was not is drawn as a path.
    func testOnlyAViaFerrataOnAnUntwinnedRoadIsDrawnAsAPath() throws {
        try write(
            """
            highway=via_ferrata & via_ferrata_scale ~ '3[+-]?' & kmap:own_twin!=yes \(road) [0x16 road_class=0 road_speed=0 resolution 24 continue]
            highway=via_ferrata & via_ferrata_scale ~ '3[+-]?' [0x3a resolution 22]
            highway=via_ferrata & kmap:own_twin!=yes \(road) [0x0e road_class=0 road_speed=0 resolution 24 continue]
            highway=via_ferrata [0x37 resolution 22]
            """
        )
        try StyleCatalog.drawFerrataAsPath(in: directory, painted: [], twinned: [0x16])
        let text = try read()
        XCTAssertTrue(text.contains("[0x3a resolution 22]"), text)
        XCTAssertFalse(text.contains("[0x37"), text)
        let path = "highway=via_ferrata \(road) [0x0e road_class=0 road_speed=0 resolution 24]"
        XCTAssertTrue(text.hasSuffix(path), text)
    }

    /// A line a person aimed by hand keeps its number and its road keeps going on to it.
    func testAHandAimedLineIsLeftAlone() throws {
        let text = """
            highway=via_ferrata & kmap:own_twin!=yes [0x0e road_class=0 road_speed=0 resolution 22 continue]
            highway=via_ferrata [0x37 resolution 22]  # kmap: was 0x2b
            """
        try write(text)
        try StyleCatalog.drawFerrataAsPath(in: directory, painted: [])
        XCTAssertEqual(try read(), text)
    }
}
