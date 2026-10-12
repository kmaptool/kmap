import XCTest

@testable import kmap

/// A road meaning a ported style draws as another road: the directive written into the
/// ported TYP, and read back for the build's road twins.
final class StylePortTwinsTests: XCTestCase {
    private func index(lines: String) throws -> RuleSetIndex {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("port-twins-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        try lines.write(to: dir.appendingPathComponent("lines"), atomically: true, encoding: .utf8)
        return try XCTUnwrap(RuleSetIndex.read(styleDirectory: dir))
    }

    /// A link that lost our number to another link wears its own road's look where
    /// that look is ported onto the road's number: the twin borrows the road's twin.
    func testALinkDrawnAsItsRoadBorrowsTheRoadsTwin() throws {
        let rules = try index(
            lines: """
                highway=primary [0x03 road_class=3 road_speed=5 resolution 18]
                highway=secondary [0x04 road_class=2 road_speed=4 resolution 19]
                highway=primary_link | highway=secondary_link [0x08 road_class=2 road_speed=3 resolution 21]
                """
        )
        let evidence = [
            "highway=primary": ["L11f15": 1400],
            "highway=secondary": ["L11f16": 2000],
            "highway=primary_link": ["L11f15": 575],
            "highway=secondary_link": ["L11f16": 367]
        ]
        let ported = StylePort.map(codesByTag: evidence, rules: rules)
        let twins = StylePort.twinsAs(ported, rules: rules)
        XCTAssertEqual(twins.map(\.ours), [0x08])
        XCTAssertEqual(twins.map(\.meaning), ["highway=secondary_link"])
        XCTAssertEqual(twins.map(\.as), [0x04])
        let typ = StylePort.typ(
            from: TypSource.parse(""),
            ported: [],
            familyID: nil,
            productID: nil,
            codePage: nil,
            twinsAs: twins
        )
        XCTAssertTrue(typ.contains("; kmap:twin-as 0x08 highway=secondary_link 0x04"), typ)
    }

    /// The borrowing a ported style declares is read back by road code.
    func testTheBorrowingIsReadFromTheTyp() throws {
        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(
            "twin-as-\(UUID().uuidString).txt"
        )
        try "; kmap:twin-as 0x08 highway=secondary_link 0x04\n; kmap:twin-as 0x08 highway=tertiary_link 0x05\n"
            .write(to: url, atomically: true, encoding: .utf8)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        let read = StylePort.twinBorrowing(in: url)
        XCTAssertEqual(read[0x08]?.map(\.tag), ["highway=secondary_link", "highway=tertiary_link"])
        XCTAssertEqual(read[0x08]?.map(\.as), [0x04, 0x05])
    }
}
