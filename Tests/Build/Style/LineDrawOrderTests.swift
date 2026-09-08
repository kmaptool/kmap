import XCTest
@testable import kmap

/// Which line covers which: the ranks kmap reads out of a style's own road rules and
/// hands to mkgmap. A wrong rank is not a crash — it is a river drawn over a motorway.
final class LineDrawOrderTests: XCTestCase {

    /// Indexes a `lines` file written into a throwaway directory.
    private func index(_ lines: String,
                       file: StaticString = #filePath, line: UInt = #line) throws -> RuleSetIndex {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("draworder-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        try lines.write(to: dir.appendingPathComponent("lines"), atomically: true, encoding: .utf8)
        return try XCTUnwrap(RuleSetIndex.read(styleDirectory: dir), "nothing parsed",
                             file: file, line: line)
    }

    func testARoadRanksAboveTheWaterItCrosses() throws {
        let index = try index("""
        waterway=river [0x1f resolution 24]
        highway=motorway [0x0100 resolution 20-24]
        highway=residential [0x0600 resolution 24]
        """)
        let ranks = LineDrawOrder.ranks(in: index)
        XCTAssertNil(ranks[0x1f], "water is not named, so it stays at the bottom")
        XCTAssertEqual(ranks[0x0600], 2)
        XCTAssertEqual(ranks[0x0100], 7)
        XCTAssertTrue(ranks[0x0100]! > ranks[0x0600]!, "a motorway covers a street")
    }

    func testTheHighestClaimOnACodeWins() throws {
        // One code drawn for two roads at once: it is drawn the same either way, so it
        // takes the rank of the more important of them.
        let index = try index("""
        highway=track [0x0a resolution 24]
        highway=primary | highway=secondary [0x0a resolution 24]
        """)
        XCTAssertEqual(LineDrawOrder.ranks(in: index)[0x0a], 5)
    }

    func testAStyleWithoutRoadsAsksForNoOrder() throws {
        let index = try index("waterway=stream [0x18 resolution 24]\n")
        XCTAssertTrue(LineDrawOrder.ranks(in: index).isEmpty)
        XCTAssertNil(LineDrawOrder.option(in: index), "nothing to rank, so mkgmap is left alone")
    }

    func testTheOptionNamesEveryRankedCode() throws {
        let index = try index("""
        highway=path [0x10a05 resolution 24]
        highway=trunk [0x02 resolution 24]
        """)
        XCTAssertEqual(LineDrawOrder.option(in: index),
                       "--x-line-draw-order=0x02:6,0x10a05:1",
                       "sorted by code, each with its rank, as the patched mkgmap reads it")
    }

    /// A rule that narrows a road with a second condition still names the road.
    func testANarrowedRoadRuleStillCounts() throws {
        let index = try index("highway=secondary & bridge=yes [0x11f15 resolution 24]\n")
        XCTAssertEqual(LineDrawOrder.ranks(in: index)[0x11f15], 4)
    }
}
