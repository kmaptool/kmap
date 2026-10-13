import XCTest

@testable import kmap

/// The codes read, resolved into claims on kmap's rules.
final class StyleRecoveryResolverTests: XCTestCase {
    /// A foreign code drawing a meaning a default rule draws claims that rule.
    func testAForeignCodeClaimsTheRuleOfWhatItDraws() throws {
        let rules = try MiniRuleBook.load()
        let path = try XCTUnwrap(rules.lines(for: "highway=path", kind: .line))
        let reading = StyleRecovery.CodeReading(
            key: "L30",
            code: {
                var code = Evidence.ForCode(kind: .line, type: 0x30)
                for id in 1...20 { code.sources[Int64(id)] = ["highway": "path"] }
                return code
            }(),
            buckets: ["path": MiniRuleBook.bucket(path, tag: "highway=path", count: 20)],
            meant: 20,
            foreign: true
        )
        var resolver = StyleRecovery.Resolver(readings: [reading], rules: rules, ground: [:])
        let outcome = resolver.resolve(resolver.readings[0])
        XCTAssertEqual(outcome.status, .resolved)
        XCTAssertEqual(resolver.claims.rules.values.flatMap { $0.codes.map(\.type) }, [0x30])
        let verdict = resolver.claims.verdicts[StyleRecovery.codeKey(.line, 0x30)]
        XCTAssertEqual(verdict?.agrees, false, "the rule emits another number")
        XCTAssertTrue(resolver.witnessedSlots.contains("L:lines:" + path[0].text))
    }

    /// A code seen once says nothing yet.
    func testACodeSeenOnceStaysASingleWitness() throws {
        let rules = try MiniRuleBook.load()
        let path = try XCTUnwrap(rules.lines(for: "highway=path", kind: .line))
        var code = Evidence.ForCode(kind: .line, type: 0x30)
        code.sources[1] = ["highway": "path"]
        let reading = StyleRecovery.CodeReading(
            key: "L30",
            code: code,
            buckets: ["path": MiniRuleBook.bucket(path, tag: "highway=path", count: 1)],
            meant: 1,
            foreign: true
        )
        var resolver = StyleRecovery.Resolver(readings: [reading], rules: rules, ground: [:])
        XCTAssertEqual(resolver.resolve(reading).status, .singleWitness)
        XCTAssertTrue(resolver.claims.rules.isEmpty)
    }
}
