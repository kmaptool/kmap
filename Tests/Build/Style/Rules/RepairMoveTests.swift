import XCTest
@testable import kmap

/// Where a borrowed style draws 0x0d, the link moves — and has to go on routing, which is
/// the one thing it is for.
final class RepairMoveTests: XCTestCase {

    private static let rule =
        "kmap:repair=* [0x0d road_class=0 road_speed=0 resolution 22]"

    private func directory(_ lines: String) throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("repair-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        try lines.write(to: dir.appendingPathComponent("lines"), atomically: true,
                        encoding: .utf8)
        return dir
    }

    private func moved(to code: Int) throws -> [String] {
        let dir = try directory(Self.rule + "\n")
        XCTAssertEqual(StyleCatalog.moveRepairRules([.line: [0x0d: code]], in: dir), 1)
        return try String(contentsOf: dir.appendingPathComponent("lines"), encoding: .utf8)
            .components(separatedBy: "\n").filter { !$0.isEmpty }
    }

    /// The plain range the TYP looks in is the range that routes.
    func testTheNumbersTheLinkMayMoveToAreTheOnesThatRoute() {
        XCTAssertEqual(TypAugment.routableLines, 0x01...0x16)
    }

    /// A number that routes takes the whole rule: one line, still a road.
    func testALinkThatFindsARoutableNumberMovesWithItsRoute() throws {
        let lines = try moved(to: 0x16)
        XCTAssertEqual(lines.count, 1)
        XCTAssertTrue(lines[0].contains("[0x16 "), lines[0])
        XCTAssertTrue(lines[0].contains("road_class=0"), "the link still routes")
        XCTAssertFalse(lines[0].contains("continue"), "nothing to draw over")
    }

    /// With every routing number taken, the link keeps 0x0d to route on and the dashes
    /// are drawn over it by a second line that carries no route.
    func testALinkWithNowhereRoutableToGoKeepsItsNumberAndIsDrawnOver() throws {
        let lines = try moved(to: 0x3f)
        XCTAssertEqual(lines.count, 2)
        XCTAssertTrue(lines[0].contains("[0x0d "), lines[0])
        XCTAssertTrue(lines[0].contains("road_class=0"), "the link still routes")
        XCTAssertTrue(lines[0].contains(" continue]"), "the drawing follows")
        XCTAssertTrue(lines[1].contains("[0x3f "), lines[1])
        XCTAssertFalse(lines[1].contains("road_class"), "a drawing is not a road")
    }
}
