import XCTest

@testable import kmap

/// What resolving the codes settled, kept per rule line.
final class StyleRecoveryClaimsTests: XCTestCase {
    func testClaimsOnOneRuleLineGatherAndTheSameTextInAnotherFileIsAnotherRule() throws {
        let rules = try MiniRuleBook.load()
        let inLines = try XCTUnwrap(rules.lines(for: "highway=footway", kind: .line)?.first)
        let inPolygons = try XCTUnwrap(rules.lines(for: "highway=footway", kind: .area)?.first)
        let meaning = MiniRuleBook.bucket([inLines], tag: "highway=footway", count: 4)
        var claims = StyleRecovery.Claims(defaultsOf: [])
        claims.claim(inLines, by: 0x30, meaning: meaning)
        claims.claim(inLines, by: 0x31, meaning: meaning)
        claims.claim(inPolygons, by: 0x30, meaning: meaning)
        XCTAssertEqual(claims.rules.count, 2)
        XCTAssertEqual(claims.rules["lines:" + inLines.text]?.codes.map(\.type), [0x30, 0x31])
        XCTAssertEqual(claims.rules["lines:" + inLines.text]?.codes.first?.weight, 4)
    }

    /// A default code claims only the lines it emits itself, and a foreign one nothing yet.
    func testADefaultCodeClaimsTheLinesItAlreadyEmits() throws {
        let rules = try MiniRuleBook.load()
        let path = try XCTUnwrap(rules.lines(for: "highway=path", kind: .line))
        let meaning = MiniRuleBook.bucket(path, tag: "highway=path", count: 10)
        let claims = StyleRecovery.Claims(defaultsOf: [
            MiniRuleBook.reading(.line, 0x16, foreign: false, ["p": meaning]),
            MiniRuleBook.reading(.line, 0x30, foreign: true, ["p": meaning]),
            MiniRuleBook.reading(.line, 0x02, foreign: false, ["p": meaning])
        ])
        XCTAssertEqual(claims.rules.values.flatMap { $0.codes.map(\.type) }, [0x16])
    }

    func testNarrowingsAdditionsAndVerdictsAreKept() throws {
        let rules = try MiniRuleBook.load()
        let path = try XCTUnwrap(rules.lines(for: "highway=path", kind: .line)?.first)
        var claims = StyleRecovery.Claims(defaultsOf: [])
        claims.narrow(path)
        claims.add(StyleRecovery.RuleAddition(tag: "a=b", key: "a", type: 0x30, witnesses: 5, ids: []), kind: .line)
        claims.judge("L30", StyleRecovery.CodeVerdict(agrees: true, meaning: "a=b"))
        XCTAssertNotNil(claims.narrowed["lines:" + path.text])
        XCTAssertEqual(claims.additions[.line]?.map(\.tag), ["a=b"])
        XCTAssertEqual(claims.verdicts["L30"]?.agrees, true)
    }
}
