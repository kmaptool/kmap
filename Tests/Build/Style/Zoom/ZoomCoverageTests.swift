import XCTest
@testable import kmap

/// The style a real build materialized, for tests that only read it.
///
/// Tests run in an isolated root where no build has happened, so the suites that need
/// mkgmap's actual rule set read the real home directory. Read-only: the shift test
/// copies before it writes.
enum ZoomRealStyle {
    static var directory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".kmap/styles/kmap-base", isDirectory: true)
    }
}

/// Whether every rule a build compiles belongs to some family.
///
/// A rule no family claims cannot be moved, and no row on screen says so. Reads the style
/// on disk; skipped where no build has run.
final class ZoomCoverageTests: XCTestCase {

    /// Rules deliberately left out, by the condition that identifies them: kmap's repair
    /// marker is a diagnostic rather than scenery.
    private static let notOffered = ["kmap:repair="]

    func testEveryRuleInTheStyleBelongsToAFamily() throws {
        let directory = ZoomRealStyle.directory
        try XCTSkipUnless(FileManager.default.fileExists(
            atPath: directory.appendingPathComponent("polygons").path),
            "no materialized style on this machine")

        var orphans: [String] = []
        var counted = 0
        for file in Set(ZoomFamily.all.flatMap(\.files)).sorted() {
            guard let text = try? String(contentsOf: directory.appendingPathComponent(file),
                                         encoding: .utf8) else { continue }
            for rule in ZoomRuleScan.rules(in: text.components(separatedBy: "\n"))
            where ZoomRuleScan.resolution(in: rule.type) != nil {
                counted += 1
                if ZoomFamily.all.contains(where: { $0.claims(rule.condition, in: file) }) {
                    continue
                }
                let condition = rule.condition.trimmingCharacters(in: .whitespaces)
                guard !Self.notOffered.contains(where: condition.contains) else { continue }
                orphans.append("\(file): \(condition.prefix(90))")
            }
        }
        XCTAssertGreaterThan(counted, 150, "the style should have rules in it to check")
        XCTAssertEqual(orphans, [], "rules no family claims, so nobody can move them")
    }

    /// A rule whose type sits on its own line still belongs to the condition above it.
    func testARuleSplitOverLinesKeepsItsCondition() {
        let rules = ZoomRuleScan.rules(in: [
            "# a comment",
            "(railway=rail | railway=tram | railway=subway) & !(tunnel=yes)",
            "\t[0x14 resolution 22]",
            "",
            "waterway=* & waterway!=no",
            "    {add name='${waterway}'} [0x26 resolution 24]",
            "highway=path [0x16 resolution 23]",
        ])
        XCTAssertEqual(rules.count, 3)
        XCTAssertTrue(rules[0].condition.contains("railway=rail"))
        // The action block is not the condition; read as one, the rule would be claimed by
        // whatever tag `add name=` mentions.
        XCTAssertTrue(rules[1].condition.contains("waterway=*"))
        XCTAssertTrue(rules[2].condition.contains("highway=path"))
        XCTAssertEqual(ZoomRuleScan.resolution(in: rules[0].type)?.value, 22)
    }

    /// A condition with no type after it is not carried across a blank line or a comment:
    /// mkgmap allows neither inside a rule, so anything still waiting was not a rule.
    func testAPendingConditionDoesNotOutliveTheRule() {
        let rules = ZoomRuleScan.rules(in: [
            "natural=wood",
            "",
            "[0x50 resolution 19]",
        ])
        XCTAssertTrue(rules.isEmpty)
    }
}
