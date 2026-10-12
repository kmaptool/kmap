import XCTest

@testable import kmap

/// A build twins the roads its own copy of the TYP draws, and nothing else.
final class RoadTwinOptionsTests: XCTestCase {
    private static let rules = """
        highway=path [0x16 road_class=0 road_speed=0 resolution 22]
        highway=residential [0x06 road_class=0 road_speed=2 resolution 22]
        waterway=stream [0x18 resolution 22]
        """

    private static let typ = """
        [_line]
        Type=0x16
        Xpm="32 1 2 1"
        "! c #303030"
        ". c none"
        "!!!..!!!..!!!..!!!..!!!..!!!..!!"
        [end]
        """

    private func root() throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("twin-options-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir
    }

    private func write(_ text: String, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    /// The path the TYP draws gets its twin; the street the receiver draws is left alone.
    func testOnlyARoadTheBuildsTypDrawsIsTwinned() throws {
        let pipeline = PipelineFixture.pipeline(workRoot: try root())
        let work = pipeline.recipe.workDirectory
        let rules = work.appendingPathComponent("style", isDirectory: true)
        try write(Self.rules, to: rules.appendingPathComponent("lines"))
        let typ = work.appendingPathComponent("typ/style.txt")
        try write(Self.typ, to: typ)

        let twinned = try pipeline.roadTwins(in: rules, typ: typ)
        XCTAssertEqual(twinned.rules, 1)
        XCTAssertEqual(twinned.roads, [0x16])
        let lines = try String(contentsOf: rules.appendingPathComponent("lines"), encoding: .utf8)
        XCTAssertTrue(lines.contains("[0x16 road_class=0 road_speed=0 resolution 24 continue]"), lines)
        XCTAssertTrue(lines.contains("highway=path [0x11f16 resolution 22]"), lines)
        XCTAssertTrue(lines.contains("highway=residential [0x06 road_class=0 road_speed=2 resolution 22]"), lines)
        XCTAssertNotNil(TypSource.parse(try String(contentsOf: typ, encoding: .utf8)).section(.line, 0x11f16))
    }

    /// A TYP outside the build's own folder is the user's: neither it nor the rules change.
    func testTheUsersOwnTypIsNeverEdited() throws {
        let pipeline = PipelineFixture.pipeline(workRoot: try root())
        let rules = pipeline.recipe.workDirectory.appendingPathComponent("style", isDirectory: true)
        try write(Self.rules, to: rules.appendingPathComponent("lines"))
        let users = try root().appendingPathComponent("mine.txt")
        try write(Self.typ, to: users)

        XCTAssertEqual(try pipeline.roadTwins(in: rules, typ: users).rules, 0)
        XCTAssertEqual(try String(contentsOf: users, encoding: .utf8), Self.typ)
        XCTAssertEqual(try String(contentsOf: rules.appendingPathComponent("lines"), encoding: .utf8), Self.rules)
    }

    /// With no TYP at all every road is the receiver's to draw.
    func testNoTypTwinsNothing() throws {
        let pipeline = PipelineFixture.pipeline(workRoot: try root())
        let rules = pipeline.recipe.workDirectory.appendingPathComponent("style", isDirectory: true)
        try write(Self.rules, to: rules.appendingPathComponent("lines"))
        XCTAssertEqual(try pipeline.roadTwins(in: rules, typ: nil).rules, 0)
    }
}
