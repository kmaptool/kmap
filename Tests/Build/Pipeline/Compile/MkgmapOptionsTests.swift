import XCTest

@testable import kmap

/// The rule snapshot a build compiles from, fitted to the TYP it compiles with.
final class MkgmapOptionsTests: XCTestCase {
    private static let lines = """
        barrier=hedge [0x3e resolution 24]
        barrier=fence [0x17 resolution 24]
        aeroway=taxiway [0x10900 resolution 24 continue]
        """
    private static let polygons = """
        building=* & building!=no & (amenity=*) [0x36 resolution 24 continue]
        leisure=stadium [0x33 resolution 20]
        building=* & building!=no [0x13 resolution 24]
        """

    private func root() throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("fit-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir
    }

    private func snapshot(of pipeline: BuildPipeline) throws -> URL {
        let rules = pipeline.recipe.workDirectory.appendingPathComponent("style", isDirectory: true)
        try FileManager.default.createDirectory(at: rules, withIntermediateDirectories: true)
        try Self.lines.write(to: rules.appendingPathComponent("lines"), atomically: true, encoding: .utf8)
        try Self.polygons.write(to: rules.appendingPathComponent("polygons"), atomically: true, encoding: .utf8)
        return rules
    }

    private func read(_ rules: URL, _ file: String) throws -> String {
        try String(contentsOf: rules.appendingPathComponent(file), encoding: .utf8)
    }

    /// With no TYP the receiver draws by number: a number of kmap's own means nothing
    /// to it, so each meaning goes back to the number it left, and a layer goes.
    func testWithNoTypEveryNumberOfKmapsOwnGoesBack() throws {
        let pipeline = PipelineFixture.pipeline(workRoot: try root())
        let rules = try snapshot(of: pipeline)
        try pipeline.fit(rules, typ: nil)
        let lines = try read(rules, "lines")
        XCTAssertTrue(lines.contains("barrier=hedge [0x17 resolution 24]"), lines)
        XCTAssertTrue(lines.contains("aeroway=taxiway [0x27 resolution 24 continue]"), lines)
        let polygons = try read(rules, "polygons")
        XCTAssertTrue(polygons.contains("leisure=stadium [0x19 resolution 20]"), polygons)
        XCTAssertFalse(polygons.contains("[0x36"), polygons)
        XCTAssertTrue(polygons.contains("building=* & building!=no [0x13 resolution 24]"), polygons)
    }

    /// A build from a rule folder of the user's own, with the TYP it stands beside.
    private func ownFolder(typ: URL? = nil) throws -> BuildPipeline {
        let folder = try root()
        return PipelineFixture.pipeline(workRoot: try root()) { recipe in
            recipe.style = MapStyle(
                id: "mine",
                name: "Mine",
                summary: "",
                origin: .customDirectory(folder),
                styleDirectory: folder,
                typURL: typ,
                familyID: 6300,
                productID: 1
            )
        }
    }

    /// A rule folder of the user's own with no TYP is compiled as written: its numbers
    /// are its own.
    func testAFolderOfTheUsersOwnWithNoTypIsCompiledAsItIs() throws {
        let pipeline = try ownFolder()
        let rules = try snapshot(of: pipeline)
        try pipeline.fit(rules, typ: nil)
        XCTAssertEqual(try read(rules, "lines"), Self.lines)
        XCTAssertEqual(try read(rules, "polygons"), Self.polygons)
    }

    /// The same folder beside a TYP written for kmap's numbers: a meaning on a number
    /// that TYP does not paint goes back to the number it does, and is not silenced.
    func testAFolderOfTheUsersOwnFollowsItsTyp() throws {
        let typ = try root().appendingPathComponent("ported.txt")
        try """
        ; \(StylePort.forOurNumbers)
        [_line]
        Type=0x17
        Xpm="0 0 1 0"
        "1 c #303030"
        [end]
        [_polygon]
        Type=0x13
        Xpm="0 0 1 0"
        "1 c #606060"
        [end]
        """.write(to: typ, atomically: true, encoding: .utf8)
        let pipeline = try ownFolder(typ: typ)
        let rules = try snapshot(of: pipeline)
        try pipeline.fit(rules, typ: nil)
        let lines = try read(rules, "lines")
        XCTAssertTrue(lines.contains("barrier=hedge [0x17 resolution 24]"), lines)
        XCTAssertTrue(lines.contains("barrier=fence [0x17 resolution 24]"), lines)
        XCTAssertFalse(try read(rules, "polygons").contains("[0x36"))
    }
}
