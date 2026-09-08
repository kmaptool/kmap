import XCTest
@testable import kmap

/// Whether a plan puts each family on the rungs it was given, and leaves the rest alone.
final class ZoomShiftTests: XCTestCase {

    private var directory: URL!
    private var catalog: StyleCatalog!
    private var log: Log!

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("zoom-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let settings = SettingsStore()
        catalog = StyleCatalog(settings: settings,
                                     toolchain: Toolchain(settings: settings))
        log = Log()
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func write(_ file: String, _ text: String) throws {
        try text.write(to: directory.appendingPathComponent(file),
                       atomically: true, encoding: .utf8)
    }

    private func read(_ file: String) throws -> String {
        try String(contentsOf: directory.appendingPathComponent(file), encoding: .utf8)
    }

    /// Windows given as rung ranges, the way the grid builds them.
    private func plan(_ windows: [String: ClosedRange<Int>]) -> ZoomPlan {
        var plan = ZoomPlan(id: "test", name: "Test", levelsID: LevelsProfile.smooth.id)
        for (family, rungs) in windows {
            plan.setWindow(.init(finest: rungs.lowerBound, coarsest: rungs.upperBound),
                           for: ZoomFamily.named(family)!)
        }
        return plan
    }

    private func apply(_ plan: ZoomPlan) throws {
        try catalog.applyZoomPlan(plan, levels: .smooth, in: directory, log: log)
    }

    // The ladder: rung 0 = 24 bits, 1 = 23, 2 = 22, 3 = 21, 4 = 19, 5 = 18, 6 = 17.

    func testOnlyTheNamedFamilyIsRewritten() throws {
        try write("lines", """
        # a comment naming highway=path, which is not a rule
        highway=path [0x16 resolution 23]
        highway=track [0x0a resolution 22 continue with_actions]
        highway=primary [0x02 resolution 18]
        railway=rail [0x14 resolution 21]
        """)
        // Trails are measured on rungs 1–2; asking for 0–3 starts them a rung earlier.
        try apply(plan(["trails": 0...3]))
        let out = try read("lines")

        XCTAssertTrue(out.contains("highway=path [0x16 resolution 22]"), out)
        XCTAssertTrue(out.contains("highway=track [0x0a resolution 21 continue with_actions]"))
        // The road and the railway are untouched, and so is the comment.
        XCTAssertTrue(out.contains("highway=primary [0x02 resolution 18]"))
        XCTAssertTrue(out.contains("railway=rail [0x14 resolution 21]"))
        XCTAssertTrue(out.contains("# a comment naming highway=path"))
    }

    func testAFamilyKeepsItsInternalSpread() throws {
        try write("lines", """
        highway=motorway [0x01 resolution 17]
        highway=primary [0x02 resolution 19]
        highway=service [0x07 resolution 24]
        """)
        // Measured across rungs 0–6; asked for 0–5, one rung in from the coarse end.
        try apply(plan(["roads": 0...5]))
        let out = try read("lines")
        // Each rule moves by the same amount rather than all landing on one number.
        XCTAssertTrue(out.contains("[0x01 resolution 18]"), out)
        XCTAssertTrue(out.contains("[0x02 resolution 21]"))
        // Already at the finest rung: it stays there rather than falling off.
        XCTAssertTrue(out.contains("[0x07 resolution 24]"))
    }

    /// A window that stops short of the closest zoom needs mkgmap's range form.
    func testACeilingIsWrittenAsARange() throws {
        try write("polygons", """
        landuse=forest [0x50 resolution 19 continue]
        natural=scrub [0x4f resolution 19]
        """)
        // Measured on rung 4 alone; asked for rungs 2–4, so it stops at 22 bits.
        try apply(plan(["woodland": 2...4]))
        let out = try read("polygons")
        XCTAssertTrue(out.contains("[0x50 resolution 19-22 continue]"), out)
        XCTAssertTrue(out.contains("[0x4f resolution 19-22]"))
    }

    /// A window reaching rung 0 has no ceiling, and says so with the plain form: writing
    /// `-24` would mean the same and read as a restriction.
    func testNoCeilingKeepsThePlainForm() throws {
        try write("polygons", "landuse=forest [0x50 resolution 19]")
        try apply(plan(["woodland": 0...3]))
        XCTAssertTrue(try read("polygons").contains("[0x50 resolution 21]"))
    }

    func testAPlanThatSaysNothingTouchesNothing() throws {
        let before = "highway=path [0x16 resolution 23]"
        try write("lines", before)
        try apply(ZoomPlan.asMeasured)
        XCTAssertEqual(try read("lines"), before,
                       "a plan with no windows should not even rewrite the file")
    }

    func testAFamilyThatMatchesNothingIsReported() throws {
        try write("lines", "highway=primary [0x02 resolution 18]")
        try apply(plan(["trails": 0...2]))
        XCTAssertTrue(log.snapshot().contains {
            $0.severity == .warn && $0.text.contains("matched no rule")
        }, "a family that changed nothing has to say so")
    }
}

/// Whether a plan reaches the rules a real build compiles.
///
/// Works on the style kmap has materialized -- mkgmap's own, with every kmap edit applied.
/// Skipped where no build has run and there is nothing to read.
final class ZoomShiftOnTheRealStyleTests: XCTestCase {

    func testMovingWoodlandOnTheStyleOnDisk() async throws {
        let source = ZoomRealStyle.directory
        try XCTSkipUnless(FileManager.default.fileExists(
            atPath: source.appendingPathComponent("polygons").path),
            "no materialized style on this machine")

        let copy = FileManager.default.temporaryDirectory
            .appendingPathComponent("zoom-real-\(UUID().uuidString.prefix(8))")
        try FileManager.default.copyItem(at: source, to: copy)
        defer { try? FileManager.default.removeItem(at: copy) }

        let before = ZoomSurvey(styleAt: copy, levels: .smooth)
        let woodland = ZoomFamily.named("woodland")!
        let was = try XCTUnwrap(before.spread(woodland), "the style should have woodland in it")
        try XCTSkipUnless(was.coarsest > 0, "woodland is already at the closest rung")

        var plan = ZoomPlan(id: "t", name: "Test", levelsID: LevelsProfile.smooth.id)
        plan.setWindow(.init(finest: max(0, was.finest - 1), coarsest: was.coarsest - 1),
                       for: woodland)
        let settings = SettingsStore()
        let catalog = StyleCatalog(settings: settings,
                                         toolchain: Toolchain(settings: settings))
        try catalog.applyZoomPlan(plan, levels: .smooth, in: copy, log: Log())

        let after = ZoomSurvey(styleAt: copy, levels: .smooth)
        let now = try XCTUnwrap(after.spread(woodland))
        XCTAssertEqual(now.rules, was.rules, "no rule should have been lost")
        XCTAssertEqual(now.coarsest, was.coarsest - 1)

        // And nothing else moved.
        for family in ZoomFamily.all where family.id != woodland.id {
            XCTAssertEqual(after.spread(family), before.spread(family),
                           "\(family.id) should not have moved")
        }
    }
}

extension ZoomShiftTests {
    /// Moving one family must not move a rule a narrower family owns: the owner is taken
    /// from the full family list, and the plan consulted afterwards.
    func testANarrowerFamilysRulesStayWhenItsNeighbourMoves() throws {
        try write("lines", """
        highway=path [0x16 resolution 23]
        highway=primary [0x02 resolution 19]
        """)
        try write("points", """
        place=city [0x01 resolution 18]
        amenity=cafe [0x2a14 resolution 24]
        """)
        var asked = ZoomPlan(id: "t", name: "T", levelsID: LevelsProfile.smooth.id)
        asked.setWindow(.init(finest: 0, coarsest: 6), for: ZoomFamily.named("roads")!)
        asked.setWindow(.init(finest: 0, coarsest: 2), for: ZoomFamily.named("pois")!)
        try catalog.applyZoomPlan(asked, levels: .smooth, in: directory, log: log)

        let lines = try read("lines")
        XCTAssertTrue(lines.contains("highway=path [0x16 resolution 23]"),
                      "the trail belongs to the trails, however the roads move")
        XCTAssertTrue(lines.contains("highway=primary [0x02 resolution 17]"), lines)
        let points = try read("points")
        XCTAssertTrue(points.contains("place=city [0x01 resolution 18]"),
                      "the town name belongs to the place names, however the POIs move")
        XCTAssertTrue(points.contains("amenity=cafe [0x2a14 resolution 22]"), points)
    }
}
