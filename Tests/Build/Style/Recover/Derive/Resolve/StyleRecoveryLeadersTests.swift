import XCTest

@testable import kmap

/// The strongest claim on each meaning, over every code.
final class StyleRecoveryLeadersTests: XCTestCase {
    func testTheStrongestClaimLeadsEachMeaningAndTag() throws {
        let rules = try MiniRuleBook.load()
        let path = try XCTUnwrap(rules.lines(for: "highway=path", kind: .line))
        let leaders = StyleRecovery.Leaders(of: [
            MiniRuleBook.reading(
                .line,
                0x30,
                foreign: true,
                ["p": MiniRuleBook.bucket(path, tag: "highway=path", count: 7)]
            ),
            MiniRuleBook.reading(
                .line,
                0x31,
                foreign: true,
                ["p": MiniRuleBook.bucket(path, tag: "highway=path", count: 3)]
            )
        ])
        XCTAssertEqual(leaders.meaning["p"], 7)
        XCTAssertEqual(leaders.tag["L@highway=path"], 7)
    }

    /// A tag counts as drawn on buildings only where buildings are a real share of it.
    func testATagIsBuiltOnlyWhereBuildingsAreARealShareOfIt() throws {
        let rules = try MiniRuleBook.load()
        let forest = try XCTUnwrap(rules.lines(for: "landuse=forest", kind: .area))
        let open = MiniRuleBook.bucket(forest, tag: "landuse=forest", count: 100)
        let houses = MiniRuleBook.bucket(forest, tag: "landuse=forest", count: 3, first: 500, built: 3)
        let leaders = StyleRecovery.Leaders(of: [
            MiniRuleBook.reading(.area, 0x50, foreign: true, ["open": open]),
            MiniRuleBook.reading(.area, 0x51, foreign: true, ["built": houses])
        ])
        let (built, openTags) = leaders.classedTags()
        XCTAssertTrue(built.isEmpty, "3 mistagged houses do not make the woods built")
        XCTAssertEqual(openTags, ["A@landuse=forest"])
    }
}
