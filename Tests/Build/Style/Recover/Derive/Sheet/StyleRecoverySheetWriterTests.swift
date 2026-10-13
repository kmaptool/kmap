import XCTest

@testable import kmap

/// The sheet written from what resolving the codes settled.
final class StyleRecoverySheetWriterTests: XCTestCase {
    private func addition(_ tag: String, _ type: Int, _ witnesses: Int) -> StyleRecovery.RuleAddition {
        StyleRecovery.RuleAddition(
            tag: tag,
            key: String(tag.split(separator: "=")[0]),
            type: type,
            witnesses: witnesses,
            ids: [Int64(witnesses)]
        )
    }

    /// 3 members of a key no rule of ours names become 1 family rule on their code.
    func testMembersOfAKeyWithoutRulesBecomeOneFamily() throws {
        let rules = try MiniRuleBook.load()
        let families = StyleRecovery.SheetWriter.families(
            of: [
                addition("shop=bakery", 0x2e01, 9), addition("shop=books", 0x2e01, 8), addition("shop=toys", 0x2e01, 7)
            ],
            kind: .point,
            rules: rules
        )
        XCTAssertEqual(families.map(\.tag), ["shop=*"])
        XCTAssertEqual(families.first?.witnesses, 24)
    }

    func testAKeyOurRulesNameStaysMemberByMember() throws {
        let rules = try MiniRuleBook.load()
        let kept = StyleRecovery.SheetWriter.families(
            of: [
                addition("amenity=bank", 0x2f06, 9), addition("amenity=atm", 0x2f06, 8),
                addition("amenity=cafe", 0x2f06, 7)
            ],
            kind: .point,
            rules: rules
        )
        XCTAssertEqual(kept.map(\.tag), ["amenity=bank", "amenity=atm", "amenity=cafe"])
    }

    /// An addition goes above the file's first rule, under a note of what was identified.
    func testAnAdditionIsWrittenAboveTheFirstRule() throws {
        let rules = try MiniRuleBook.load()
        var claims = StyleRecovery.Claims(defaultsOf: [])
        claims.add(addition("leisure=park", 0x20, 6), kind: .area)
        var writer = StyleRecovery.SheetWriter(claims: claims, witnessedSlots: [], typDefined: [:], rules: rules)
        let sheet = writer.write()
        XCTAssertEqual(sheet.first, "@@ polygons")
        XCTAssertTrue(sheet.contains { $0.hasPrefix("+ leisure=park [0x20 resolution ") }, "\(sheet)")
        XCTAssertEqual(sheet.last, "+ highway=footway [0x16 resolution 23]")
    }
}
