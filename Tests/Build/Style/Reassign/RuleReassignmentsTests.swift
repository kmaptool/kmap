import XCTest
@testable import kmap

/// Moving a rule onto a different Garmin type. A reassignment is an exact-line substitution
/// against the installed mkgmap's rule set: a block that differs anywhere matches nothing and
/// is reported missed, and a block matching twice moves both copies.
final class RuleReassignmentsTests: XCTestCase {

    private var store: URL!

    override func setUpWithError() throws {
        let folder = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("reassign-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        store = folder.appendingPathComponent("reassignments.txt")
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
    }

    private func move(_ raw: String, from: Int, to: Int, file: String = "points",
                      note: String = "") -> RuleReassignment {
        RuleReassignment(file: file, raw: raw, fromCode: from, toCode: to, note: note)
    }

    // MARK: What gets written

    func testASingleLineRuleIsRecordedAsItStandsAndWithItsNewType() throws {
        try RuleReassignments.add(
            move("shop=car_wrecker [0x2f0a resolution 24]", from: 0x2f0a, to: 0x2f03,
                 note: "same spanner as car_repair"),
            to: store)

        let entry = try XCTUnwrap(RuleReassignments.entries(in: store).first)
        XCTAssertEqual(entry.file, "points")
        XCTAssertEqual(entry.old, ["shop=car_wrecker [0x2f0a resolution 24]"])
        XCTAssertEqual(entry.new,
                       ["shop=car_wrecker [0x2f03 resolution 24]"
                        + "  # kmap: same spanner as car_repair"])
    }

    /// The resolution and anything after it are carried across untouched, so only the type
    /// changes.
    func testWhatFollowsTheTypeInsideTheBracketsIsCarriedAcross() throws {
        try RuleReassignments.add(
            move("amenity=atm [0x2f06 resolution 24 continue]", from: 0x2f06, to: 0x2f01),
            to: store)
        XCTAssertEqual(RuleReassignments.entries(in: store).first?.new,
                       ["amenity=atm [0x2f01 resolution 24 continue]"])
    }

    /// A rule written across two lines is substituted whole; the bracket line on its own is
    /// not unique.
    func testATwoLineRuleIsRecordedWithBothOfItsLines() throws {
        let raw = "cuisine=chinese | cuisine=vietnamese\n    [0x2a04 resolution 22]"
        try RuleReassignments.add(move(raw, from: 0x2a04, to: 0x2a02), to: store)

        let entry = try XCTUnwrap(RuleReassignments.entries(in: store).first)
        XCTAssertEqual(entry.old, ["cuisine=chinese | cuisine=vietnamese",
                                   "    [0x2a04 resolution 22]"])
        XCTAssertEqual(entry.new, ["cuisine=chinese | cuisine=vietnamese",
                                   "    [0x2a02 resolution 22]"])
        // The second line's indentation is part of the exact match.
        XCTAssertTrue(entry.new[1].hasPrefix("    "))
    }

    /// Only the type bracket changes: matching the bare number could hit a resolution with
    /// the same digits.
    func testOnlyTheTypeIsSwappedAndNotSomethingThatLooksLikeIt() throws {
        try RuleReassignments.add(
            move("highway=path [0x16 resolution 22]", from: 0x16, to: 0x17,
                 file: "lines"),
            to: store)
        XCTAssertEqual(RuleReassignments.entries(in: store).first?.new,
                       ["highway=path [0x17 resolution 22]"])
    }

    func testAnExtendedTypeKeepsItsWidth() throws {
        try RuleReassignments.add(
            move("highway=track [0x10801 resolution 22]", from: 0x10801, to: 0x10802,
                 file: "lines"),
            to: store)
        XCTAssertEqual(RuleReassignments.entries(in: store).first?.new,
                       ["highway=track [0x10802 resolution 22]"])
    }

    // MARK: The file it produces

    func testTheFileIsInTheSameFormKmapAppliesItsOwnSubstitutionsFrom() throws {
        try RuleReassignments.add(move("amenity=bank [0x2f06 resolution 24]",
                                       from: 0x2f06, to: 0x2f01), to: store)
        let text = RuleReassignments.text(in: store)
        XCTAssertTrue(text.contains("@@ points"), text)
        XCTAssertTrue(text.contains("- amenity=bank [0x2f06 resolution 24]"), text)
        XCTAssertTrue(text.contains("+ amenity=bank [0x2f01 resolution 24]"), text)
        XCTAssertTrue(text.hasPrefix("#"), "it opens with an explanation of itself")
    }

    func testSeveralReassignmentsAccumulate() throws {
        try RuleReassignments.add(move("a=1 [0x01 resolution 24]", from: 1, to: 2), to: store)
        try RuleReassignments.add(move("b=2 [0x03 resolution 24]", from: 3, to: 4), to: store)
        XCTAssertEqual(RuleReassignments.entries(in: store).count, 2)
    }

    /// Two substitutions on the same line conflict: the first applies and the second reports
    /// itself missed, so the second is refused.
    func testTheSameRuleCannotBeMovedTwice() throws {
        let rule = move("a=1 [0x01 resolution 24]", from: 1, to: 2)
        try RuleReassignments.add(rule, to: store)
        XCTAssertThrowsError(try RuleReassignments.add(rule, to: store))
        XCTAssertEqual(RuleReassignments.entries(in: store).count, 1)
    }

    // MARK: Undoing

    func testRemovingOnePutsThatRuleBackAndLeavesTheOthers() throws {
        try RuleReassignments.add(move("a=1 [0x01 resolution 24]", from: 1, to: 2), to: store)
        try RuleReassignments.add(move("b=2 [0x03 resolution 24]", from: 3, to: 4), to: store)

        let first = try XCTUnwrap(RuleReassignments.entries(in: store).first)
        try RuleReassignments.remove(first, from: store)

        let left = RuleReassignments.entries(in: store)
        XCTAssertEqual(left.count, 1)
        XCTAssertEqual(left.first?.old, ["b=2 [0x03 resolution 24]"])
        XCTAssertFalse(RuleReassignments.text(in: store).contains("a=1"),
                       "nothing of the removed block may be left behind")
    }

    func testRemovingATwoLineBlockTakesBothOfItsLines() throws {
        let raw = "cuisine=chinese\n    [0x2a04 resolution 22]"
        try RuleReassignments.add(move(raw, from: 0x2a04, to: 0x2a02), to: store)
        try RuleReassignments.remove(try XCTUnwrap(RuleReassignments.entries(in: store).first),
                                     from: store)
        XCTAssertTrue(RuleReassignments.isEmpty(in: store))
        XCTAssertFalse(RuleReassignments.text(in: store).contains("0x2a04"))
    }

    func testAnEmptyStoreIsEmptyRatherThanAnError() {
        XCTAssertTrue(RuleReassignments.isEmpty(in: store))
        XCTAssertEqual(RuleReassignments.entries(in: store), [])
        XCTAssertEqual(RuleReassignments.text(in: store), "")
    }

    // MARK: Actually applying to a rule set

    /// Performs the substitution exactly as `StyleCatalog` does: the recorded `-` text must
    /// be found verbatim, and the rest of the file is left alone.
    private func apply(_ entry: RuleReassignments.Entry, to text: String) -> String? {
        let old = entry.old.joined(separator: "\n")
        guard text.contains(old) else { return nil }
        return text.replacingOccurrences(of: old,
                                         with: entry.new.joined(separator: "\n"))
    }

    func testTheRecordedTextIsFoundInTheRuleFileAndSwapsOnlyThatRule() throws {
        let points = """
            amenity=atm [0x2f06 resolution 24 continue]
            amenity=bank [0x2f06 resolution 24]
            amenity=pharmacy [0x2e0d resolution 24]
            """
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("rules-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        try points.write(to: dir.appendingPathComponent("points"), atomically: true,
                         encoding: .utf8)

        // The rule is taken from the index, as the screen does, rather than retyped.
        let index = try XCTUnwrap(RuleSetIndex.read(styleDirectory: dir))
        let bank = try XCTUnwrap(index.meaning(.point, 0x2f06)?.rules
            .first { $0.condition == "amenity=bank" })

        try RuleReassignments.add(
            move(bank.raw, from: 0x2f06, to: 0x2f01, note: "banks apart from cash machines"),
            to: store)
        let entry = try XCTUnwrap(RuleReassignments.entries(in: store).first)

        let after = try XCTUnwrap(apply(entry, to: points), "the recorded text was not found")
        XCTAssertTrue(after.contains("amenity=bank [0x2f01 resolution 24]"), after)
        XCTAssertTrue(after.contains("amenity=atm [0x2f06 resolution 24 continue]"),
                      "the other rule on the same code must be left where it was")
        XCTAssertTrue(after.contains("amenity=pharmacy [0x2e0d resolution 24]"))
        XCTAssertEqual(after.components(separatedBy: "\n").count,
                       points.components(separatedBy: "\n").count)
    }

    func testATwoLineRuleIsSwappedWholeWithoutDisturbingItsNeighbours() throws {
        let points = """
            amenity=restaurant & cuisine!=*
                [0x2a00 resolution 22]
            cuisine=chinese | cuisine=vietnamese
                [0x2a04 resolution 22]
            """
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("rules-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        try points.write(to: dir.appendingPathComponent("points"), atomically: true,
                         encoding: .utf8)

        let index = try XCTUnwrap(RuleSetIndex.read(styleDirectory: dir))
        let chinese = try XCTUnwrap(index.meaning(.point, 0x2a04)?.rules.first)
        try RuleReassignments.add(move(chinese.raw, from: 0x2a04, to: 0x2a02), to: store)

        let after = try XCTUnwrap(apply(try XCTUnwrap(RuleReassignments.entries(in: store).first),
                                        to: points))
        XCTAssertTrue(after.contains("cuisine=chinese | cuisine=vietnamese\n    [0x2a02"), after)
        XCTAssertTrue(after.contains("amenity=restaurant & cuisine!=*\n    [0x2a00 resolution 22]"),
                      "the restaurant rule above it must be untouched")
    }

    /// Against the rule set a build uses: a reassignment built from the index occurs exactly
    /// once in the file it came from.
    func testAReassignmentBuiltFromTheRealRuleSetMatchesTheRealFile() throws {
        let dir = StyleCatalog.baseStyleDirectory
        let points = dir.appendingPathComponent("points")
        try XCTSkipUnless(FileTools.exists(points), "no materialized style — build once first")

        let text = try String(contentsOf: points, encoding: .utf8)
        let index = try XCTUnwrap(RuleSetIndex.read(styleDirectory: dir))
        let bank = try XCTUnwrap(index.meaning(.point, 0x2f06)?.rules
            .first { $0.condition.contains("amenity=bank") })

        try RuleReassignments.add(move(bank.raw, from: 0x2f06, to: 0x2f01), to: store)
        let entry = try XCTUnwrap(RuleReassignments.entries(in: store).first)

        XCTAssertEqual(RuleSetIndex.occurrences(of: entry.old.joined(separator: "\n"),
                                                in: text), 1)
        let after = try XCTUnwrap(apply(entry, to: text))
        XCTAssertNotEqual(after, text)
        XCTAssertEqual(after.components(separatedBy: "\n").count,
                       text.components(separatedBy: "\n").count,
                       "a reassignment adds and removes no lines")
    }

    // MARK: The materialized style's identity

    /// The fingerprint enters the materialized style's identity, so a build cannot reuse a
    /// style made before the reassignment.
    func testTheFingerprintChangesWithTheContents() throws {
        XCTAssertEqual(RuleReassignments.fingerprint(in: store), "")

        try RuleReassignments.add(move("a=1 [0x01 resolution 24]", from: 1, to: 2), to: store)
        let one = RuleReassignments.fingerprint(in: store)
        XCTAssertFalse(one.isEmpty)

        try RuleReassignments.add(move("b=2 [0x03 resolution 24]", from: 3, to: 4), to: store)
        XCTAssertNotEqual(RuleReassignments.fingerprint(in: store), one)
    }

    func testTheFingerprintIsTheSameForTheSameContents() throws {
        try RuleReassignments.add(move("a=1 [0x01 resolution 24]", from: 1, to: 2), to: store)
        let before = RuleReassignments.fingerprint(in: store)
        XCTAssertEqual(RuleReassignments.fingerprint(in: store), before)
    }

    /// A reassignment to a different target stamps a different identity, so a build cannot
    /// reuse the style made for the first.
    func testMovingToADifferentTypeGivesADifferentFingerprint() throws {
        try RuleReassignments.add(move("a=1 [0x01 resolution 24]", from: 1, to: 2), to: store)
        let toTwo = RuleReassignments.fingerprint(in: store)

        try RuleReassignments.removeAll(at: store)
        try RuleReassignments.add(move("a=1 [0x01 resolution 24]", from: 1, to: 3), to: store)
        XCTAssertNotEqual(RuleReassignments.fingerprint(in: store), toTwo)
    }
}
