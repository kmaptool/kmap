import XCTest

@testable import kmap

/// A receiver picks a plain line under the cursor before a road, so each road is routed on
/// the finest level and drawn on every level by a plain twin the cursor finds.
final class RoadTwinsTests: XCTestCase {
    private func directory(_ lines: String, includes: [String: String] = [:]) throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("twins-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        try lines.write(to: dir.appendingPathComponent("lines"), atomically: true, encoding: .utf8)
        for (name, text) in includes {
            let url = dir.appendingPathComponent(name)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try text.write(to: url, atomically: true, encoding: .utf8)
        }
        return dir
    }

    private func lines(in dir: URL) throws -> [String] {
        try String(contentsOf: dir.appendingPathComponent("lines"), encoding: .utf8)
            .components(separatedBy: "\n").filter { !$0.isEmpty }
    }

    /// The codes offered for a twin, and every code the rules emit.
    private func offered(_ dir: URL) throws -> (roads: Set<Int>, taken: Set<Int>)? {
        var asked: (roads: Set<Int>, taken: Set<Int>)?
        try StyleCatalog.addRoadTwins(finest: 24, in: dir) { roads, taken in
            asked = (roads, taken)
            return [:]
        }
        return asked
    }

    /// A code some rule draws as a plain line keeps its look, and so do kmap's repair links.
    func testOnlyCodesEmittedAsRoadsAloneAreTwinned() throws {
        let dir = try directory(
            """
            highway=path [0x16 road_class=0 road_speed=0 resolution 22]
            highway=track [0x0a road_class=0 road_speed=1 resolution 22]
            man_made=pier [0x0a resolution 23]
            kmap:repair=* [0x0d road_class=0 road_speed=0 resolution 22]
            # highway=steps [0x12 road_class=0 road_speed=0 resolution 22]
            """
        )
        let asked = try offered(dir)
        XCTAssertEqual(asked?.roads, [0x16])
        XCTAssertEqual(asked?.taken, [0x16, 0x0a, 0x0d])
    }

    /// The road keeps its number on the finest level and goes on; the twin repeats the
    /// condition and actions under the twin's number on the levels the road had.
    func testARoadRuleIsSplitIntoTheRoadAndItsTwin() throws {
        let dir = try directory(
            "highway=path {name '${ref}'} [0x16 road_class=0 road_speed=0 resolution 22]  # a note\n"
        )
        XCTAssertEqual(try StyleCatalog.addRoadTwins(finest: 24, in: dir) { _, _ in [0x16: 0x11f16] }, 1)
        let out = try lines(in: dir)
        XCTAssertEqual(out.count, 2)
        XCTAssertEqual(
            out[0],
            "highway=path {name '${ref}'} [0x16 road_class=0 road_speed=0 resolution 24 continue]  # a note"
        )
        XCTAssertEqual(out[1], "highway=path {name '${ref}'} [0x11f16 resolution 22]")
    }

    /// The road runs its actions on a copy; the twin runs them on the element and passes
    /// them on, as the road rule did.
    func testARuleThatContinuesWithItsActionsEndsSoAfterItsTwin() throws {
        let dir = try directory(
            "highway=pedestrian {set x=y} [0x16 road_class=0 road_speed=0 resolution 22 continue with_actions]\n"
        )
        try StyleCatalog.addRoadTwins(finest: 24, in: dir) { _, _ in [0x16: 0x11f16] }
        let out = try lines(in: dir)
        XCTAssertEqual(
            out[0],
            "highway=pedestrian {set x=y} [0x16 road_class=0 road_speed=0 resolution 24 continue]"
        )
        XCTAssertEqual(out[1], "highway=pedestrian {set x=y} [0x11f16 resolution 22 continue with_actions]")
    }

    /// A condition on the lines above its type is carried to the twin, which would
    /// otherwise join the road's rule as a 2nd type.
    func testAConditionOnTheLineAboveIsCarriedToTheTwin() throws {
        let dir = try directory(
            """
            highway=turning_loop | highway=layby  # places
                [0x07 road_class=0 road_speed=0 resolution 24]
            """
        )
        try StyleCatalog.addRoadTwins(finest: 24, in: dir) { _, _ in [0x07: 0x11f07] }
        let out = try lines(in: dir)
        XCTAssertEqual(out[1], "    [0x07 road_class=0 road_speed=0 resolution 24 continue]")
        XCTAssertEqual(out[2], "highway=turning_loop | highway=layby [0x11f07 resolution 24]")
    }

    /// Rules of actions alone above the road are rules of their own, not its condition.
    func testRulesOfActionsAloneAboveAreNotTheTwinsCondition() throws {
        let dir = try directory(
            """
            highway=yes {set highway=footway}   highway=pedestrian {set x=y}
                [0x16 road_class=0 road_speed=0 resolution 22]
            highway=trail {set highway=path; add bicycle=no}
            highway=path & (a=b |
                c=d) [0x16 road_class=0 road_speed=0 resolution 22]
            """
        )
        try StyleCatalog.addRoadTwins(finest: 24, in: dir) { _, _ in [0x16: 0x11f16] }
        let out = try lines(in: dir)
        XCTAssertEqual(out[2], "highway=pedestrian {set x=y} [0x11f16 resolution 22]")
        XCTAssertEqual(out[6], "highway=path & (a=b | c=d) [0x11f16 resolution 22]")
    }

    /// A `${tag}` in a condition is part of it, not an action block.
    func testATagReferenceInAConditionStaysInIt() throws {
        let dir = try directory(
            """
            a=b {set c=d}
            highway=path & name=${ref} & foo=bar {set e='${ref}'}
              [0x16 road_class=0 road_speed=0 resolution 22]
            """
        )
        try StyleCatalog.addRoadTwins(finest: 24, in: dir) { _, _ in [0x16: 0x11f16] }
        XCTAssertEqual(
            try lines(in: dir).last,
            "highway=path & name=${ref} & foo=bar {set e='${ref}'} [0x11f16 resolution 22]"
        )
    }

    /// A rule of actions alone followed by a type on its own line is that type's rule.
    func testATypeOnTheLineAfterActionsBelongsToThem() throws {
        let dir = try directory(
            """
            highway=path {
                set a=b;
            }
              [0x16 road_class=0 road_speed=0 resolution 22]
            """
        )
        try StyleCatalog.addRoadTwins(finest: 24, in: dir) { _, _ in [0x16: 0x11f16] }
        XCTAssertEqual(try lines(in: dir).last, "highway=path { set a=b; } [0x11f16 resolution 22]")
    }

    /// `level` gives way to the finest resolution on the road and stays on the twin, with
    /// the default name on both.
    func testLevelsAndTheDefaultNameStayWithTheTwin() throws {
        let dir = try directory("highway=path [0x16 road_class=0 level 2 default_name 'a b']\n")
        try StyleCatalog.addRoadTwins(finest: 24, in: dir) { _, _ in [0x16: 0x11f16] }
        let out = try lines(in: dir)
        XCTAssertEqual(out[0], "highway=path [0x16 road_class=0 default_name 'a b' resolution 24 continue]")
        XCTAssertEqual(out[1], "highway=path [0x11f16 level 2 default_name 'a b']")
    }

    /// Rules the split could change the meaning of keep their road whole: several types to
    /// 1 rule, a type joining the rule above, a road kept off the finest level, and a road
    /// in an included file.
    func testRulesThatCannotBeSplitKeepTheirCode() throws {
        let dir = try directory(
            """
            a=b [0x02 road_class=4 resolution 18] [0x10101 resolution 18]
            c=d [0x03 road_class=3 resolution 20]
                [0x10102 resolution 20]
            e=f [0x04 road_class=2 resolution 20-23]
            include 'inc/roads';
            g=h [0x05 road_class=1 resolution 22]
            i=j [0x16 road_class=0 resolution 22]
            """,
            includes: ["inc/roads": "k=l [0x05 road_class=1 resolution 22] # a road\nm=n [0x18 resolution 22]\n"]
        )
        let asked = try offered(dir)
        XCTAssertEqual(asked?.roads, [0x16])
        XCTAssertEqual(asked?.taken, [0x02, 0x10101, 0x03, 0x10102, 0x04, 0x05, 0x16, 0x18])
    }

    /// A rule mkgmap could not read, or an include that cannot be followed, leaves the
    /// file as it is.
    func testAFileNotReadWithCertaintyIsLeftAlone() throws {
        for text in [
            "highway=path [0x16 road_class=0 resolution 22 colour red]\n",
            "include 'missing';\nhighway=path [0x16 road_class=0 resolution 22]\n",
            "if (highway=*) then\nhighway=path [0x16 road_class=0 resolution 22]\nend\n"
        ] {
            let dir = try directory(text)
            XCTAssertNil(try offered(dir), text)
            XCTAssertEqual(try String(contentsOf: dir.appendingPathComponent("lines"), encoding: .utf8), text)
        }
    }

    /// Plain lines, repair links, a commented bracket and roads the table does not name
    /// stay as they were.
    func testWhatIsNotATwinnedRoadIsLeftAlone() throws {
        let text = """
            waterway=stream [0x18 resolution 22]
            kmap:repair=* [0x0d road_class=0 road_speed=0 resolution 22]
            highway=track {set a=b} # [0x16 road_class=0]
              [0x0a road_class=0 road_speed=1 resolution 22]
            """
        let dir = try directory(text)
        XCTAssertEqual(try StyleCatalog.addRoadTwins(finest: 24, in: dir) { _, _ in [0x16: 0x11f16, 0x0d: 0x0d] }, 0)
        XCTAssertEqual(try lines(in: dir), text.components(separatedBy: "\n"))
    }

    /// Both ladders route on resolution 24.
    func testTheFinestLevelIsReadFromTheLadder() {
        XCTAssertEqual(LevelsProfile.smooth.finest, 24)
        XCTAssertEqual(LevelsProfile.standard.finest, 24)
    }
}
