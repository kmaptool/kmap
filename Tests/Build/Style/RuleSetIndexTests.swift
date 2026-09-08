import XCTest
@testable import kmap

/// Reading the meaning of a Garmin type code back out of the rule set.
///
/// A dropped rule does not fail loudly: it under-reports what a code means, and the style
/// editor then offers a replacement type on bad information.
final class RuleSetIndexTests: XCTestCase {

    /// Writes rule files into a throwaway directory and indexes them.
    private func index(points: String = "", lines: String = "", polygons: String = "",
                       includes: [String: String] = [:],
                       file: StaticString = #filePath, line: UInt = #line) throws -> RuleSetIndex {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ruleset-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }

        for (name, text) in [("points", points), ("lines", lines), ("polygons", polygons)]
        where !text.isEmpty {
            try text.write(to: dir.appendingPathComponent(name), atomically: true, encoding: .utf8)
        }
        for (name, text) in includes {
            let url = dir.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try text.write(to: url, atomically: true, encoding: .utf8)
        }
        let result = RuleSetIndex.read(styleDirectory: dir)
        return try XCTUnwrap(result, "nothing parsed", file: file, line: line)
    }

    // MARK: The two rule shapes

    func testARuleWrittenOnOneLineIsFiledUnderTheCodeItEmits() throws {
        let index = try index(points: "amenity=bank [0x2f06 resolution 24]\n")
        let meaning = try XCTUnwrap(index.meaning(.point, 0x2f06))
        XCTAssertEqual(meaning.tags, ["amenity=bank"])
    }

    /// mkgmap's restaurant block puts the condition on one line and the type on the next;
    /// attributing those to an empty condition loses the meaning of the codes they emit.
    func testAConditionOnTheLineAboveItsTypeIsStillItsCondition() throws {
        let index = try index(points: """
            amenity=restaurant & cuisine!=*
                [0x2a00 resolution 22]
            cuisine=chinese | cuisine=vietnamese
                [0x2a04 resolution 22]
            """)
        XCTAssertEqual(index.meaning(.point, 0x2a00)?.tags, ["amenity=restaurant"])
        XCTAssertEqual(index.meaning(.point, 0x2a04)?.tags,
                       ["cuisine=chinese", "cuisine=vietnamese"])
    }

    /// An action block alone on the line is a continuation, not a new condition.
    func testAnActionBlockDoesNotBecomeTheCondition() throws {
        let index = try index(points: """
            amenity=cafe & internet_access=*
                {name 'Internet(${internet_access})'} [0x2f12 resolution 22 continue]
            """)
        XCTAssertEqual(index.meaning(.point, 0x2f12)?.tags, ["amenity=cafe"])
    }

    /// Contours are written across three lines with the action block between the condition
    /// and the type; the block must not replace the condition.
    func testAnActionBlockBetweenAConditionAndItsTypeDoesNotEraseTheCondition() throws {
        let index = try index(lines: """
            contour=elevation & contour_ext=elevation_minor
            \t{ name '${ele|conv:m=>ft}'; }
            \t[0x20 resolution 23]
            """)
        XCTAssertEqual(index.meaning(.line, 0x20)?.tags,
                       ["contour=elevation", "contour_ext=elevation_minor"])
    }

    /// A condition left hanging on `|` is finished by the next line, not replaced by it.
    func testAConditionBrokenAcrossLinesIsJoinedRatherThanTruncated() throws {
        let index = try index(points: """
            shop=bakery |
            shop=organic [0x2e02 resolution 24]
            """)
        XCTAssertEqual(index.meaning(.point, 0x2e02)?.tags, ["shop=bakery", "shop=organic"])
    }

    // MARK: What must not be counted

    func testTheFinalizerSectionEmitsNothing() throws {
        let index = try index(points: """
            amenity=bank [0x2f06 resolution 24]
            <finalize>
            name=* {name '${name}'} [0x9999 resolution 24]
            """)
        XCTAssertNotNil(index.meaning(.point, 0x2f06))
        XCTAssertNil(index.meaning(.point, 0x9999),
                     "the finalizer runs on elements that already matched and emits no types")
    }

    func testACommentedOutRuleIsNotARule() throws {
        let index = try index(points: """
            # amenity=bank [0x2f06 resolution 24]
            amenity=atm [0x2f07 resolution 24]
            """)
        XCTAssertNil(index.meaning(.point, 0x2f06))
        XCTAssertNotNil(index.meaning(.point, 0x2f07))
    }

    /// The hide feature comments the type off the end of a rule, so a trailing comment is
    /// never part of the condition.
    func testATrailingCommentIsNotPartOfTheCondition() throws {
        let index = try index(points:
            "amenity=bank [0x2f06 resolution 24]  # kmap: same key as atm\n")
        XCTAssertEqual(index.meaning(.point, 0x2f06)?.conditions, ["amenity=bank"])
    }

    // MARK: Includes

    /// Contours reach the map through `include 'inc/contour_lines'`, so a reader that stops
    /// at the top-level file finds no contour types.
    func testAnIncludedFileContributesItsTypes() throws {
        let index = try index(
            lines: "include 'inc/contour_lines';\nhighway=path [0x16 resolution 22]\n",
            includes: ["inc/contour_lines":
                "contour=elevation & contour_ext=elevation_minor [0x20 resolution 24]\n"])
        XCTAssertNotNil(index.meaning(.line, 0x16))
        XCTAssertNotNil(index.meaning(.line, 0x20), "contour types come in through the include")
    }

    // MARK: Tags

    /// One code may carry several meanings; every condition reaching it contributes its tags.
    func testOneCodeCarriesEveryTagThatReachesIt() throws {
        let index = try index(points: """
            shop=convenience [0x2e02 resolution 24]
            shop=bakery [0x2e02 resolution 24]
            amenity=supermarket [0x2e02 resolution 24]
            """)
        let meaning = try XCTUnwrap(index.meaning(.point, 0x2e02))
        XCTAssertEqual(meaning.tags, ["shop=convenience", "shop=bakery", "amenity=supermarket"])
        XCTAssertEqual(meaning.conditions.count, 3)
    }

    /// A wildcard is a weaker meaning, not a non-meaning: a mop-up rule may be the only one
    /// reaching its code.
    func testAMopUpWildcardIsTheMeaningWhenNothingConcreteIsNamed() {
        XCTAssertEqual(RuleSetIndex.distillTags(from: ["man_made=* & area!=no"]), ["man_made=*"])
    }

    /// A key that only qualifies the rule, such as `name=*`, says the thing is named rather
    /// than what it is.
    func testAKeyThatOnlyQualifiesTheRuleIsNotAMeaning() {
        XCTAssertEqual(RuleSetIndex.distillTags(from: ["shop=* & name=*"]), ["shop=*"])
        XCTAssertEqual(RuleSetIndex.distillTags(from: ["highway=path & oneway=yes"]),
                       ["highway=path"])
    }

    func testAWildcardGivesWayToAConcreteValueInTheSameCondition() {
        // `name=*` qualifies the rule; `leisure=park` is what the thing is.
        XCTAssertEqual(RuleSetIndex.distillTags(from: ["leisure=park & name=*"]), ["leisure=park"])
    }

    func testANegationIsNotAMeaning() {
        // `cuisine!=*` says which restaurants the rule does NOT cover.
        XCTAssertEqual(RuleSetIndex.distillTags(from: ["amenity=restaurant & cuisine!=*"]),
                       ["amenity=restaurant"])
    }

    func testInternalKeysAreNotMeanings() {
        // `kmap:on` is written onto nodes by kmap's own pass; it describes the rule's
        // context, not the object.
        XCTAssertEqual(RuleSetIndex.distillTags(from: ["barrier=gate & kmap:on=fence"]),
                       ["barrier=gate"])
        XCTAssertEqual(RuleSetIndex.distillTags(from: ["highway=motorway & mkgmap:fast_road=yes"]),
                       ["highway=motorway"])
    }

    func testTheSameTagReachingACodeTwiceIsListedOnce() {
        XCTAssertEqual(RuleSetIndex.distillTags(from: ["shop=car", "shop=car & service=repair"]),
                       ["shop=car", "service=repair"])
    }

    // MARK: The exact text a reassignment substitutes on

    /// A reassignment substitutes on the rule's text, so the recorded text must be what the
    /// file holds, spacing and all; the bracket line on its own is not unique.
    func testARuleKeepsTheExactTextItHasInTheFile() throws {
        let text = "amenity=bank [0x2f06 resolution 24]\n"
        let index = try index(points: text)
        let rule = try XCTUnwrap(index.meaning(.point, 0x2f06)?.rules.first)
        XCTAssertEqual(rule.raw, "amenity=bank [0x2f06 resolution 24]")
        XCTAssertTrue(text.contains(rule.raw))
        XCTAssertEqual(rule.tail, "resolution 24")
    }

    func testATwoLineRuleKeepsBothOfItsLines() throws {
        let text = "cuisine=chinese | cuisine=vietnamese\n    [0x2a04 resolution 22]\n"
        let index = try index(points: text)
        let rule = try XCTUnwrap(index.meaning(.point, 0x2a04)?.rules.first)
        XCTAssertEqual(rule.raw,
                       "cuisine=chinese | cuisine=vietnamese\n    [0x2a04 resolution 22]")
        XCTAssertTrue(text.contains(rule.raw))
    }

    func testAThreeLineRuleKeepsItsActionBlockInTheMiddle() throws {
        let text = "contour=elevation & contour_ext=elevation_minor\n"
                 + "\t{ name '${ele|conv:m=>ft}'; }\n\t[0x20 resolution 23]\n"
        let index = try index(lines: text)
        let rule = try XCTUnwrap(index.meaning(.line, 0x20)?.rules.first)
        XCTAssertEqual(rule.raw.components(separatedBy: "\n").count, 3)
        XCTAssertTrue(text.contains(rule.raw))
        XCTAssertTrue(rule.raw.contains("conv:m=>ft"), "the action block is part of the rule")
    }

    /// The tail carries the resolution and anything after it; dropping it would change the
    /// zoom a feature appears at as well as its type.
    func testTheTailAfterTheCodeIsKept() throws {
        let index = try index(points:
            "amenity=atm [0x2f06 resolution 24 continue with_actions]\n")
        XCTAssertEqual(index.meaning(.point, 0x2f06)?.rules.first?.tail,
                       "resolution 24 continue with_actions")
    }

    // MARK: Formatting

    func testACodeIsWrittenTheWayTheRuleFilesWriteIt() {
        XCTAssertEqual(TypeMeaning.hex(0x16), "0x16")
        XCTAssertEqual(TypeMeaning.hex(0x2f06), "0x2f06")
    }

    // MARK: Against the real thing

    /// mkgmap's rule set as materialized on this machine. Skipped where there is none: it is
    /// unpacked from mkgmap.jar on the first build.
    func testTheMaterializedStyleParsesIntoTheTypesTheMapActuallyUses() throws {
        let dir = StyleCatalog.baseStyleDirectory
        try XCTSkipUnless(FileTools.exists(dir.appendingPathComponent("points")),
                          "no materialized style — run a build first")
        let index = try XCTUnwrap(RuleSetIndex.read(styleDirectory: dir))

        // Loose bounds: the rule set travels with the installed mkgmap, so an exact figure
        // would fail on upgrade.
        XCTAssertGreaterThan(index.codes(.point).count, 100)
        XCTAssertGreaterThan(index.codes(.line).count, 30)
        XCTAssertGreaterThan(index.codes(.polygon).count, 40)

        // Spot checks on codes whose meaning is settled and documented in the TYP source.
        XCTAssertEqual(index.meaning(.point, 0x2a00)?.tags.first, "amenity=restaurant")
        XCTAssertTrue(index.meaning(.line, 0x20)?.tags.isEmpty == false,
                      "contour lines must come through the include")

        // Every code must carry at least one readable meaning.
        for meaning in index.all {
            XCTAssertFalse(meaning.conditions.isEmpty,
                           "\(meaning.kind) \(meaning.hex) has no rule text")
        }
    }

    /// Every rule's recorded text must occur in the file it came from, and occur once: a
    /// span that is not found substitutes nothing, and one found twice moves both copies.
    func testEveryRuleSpanIsFoundExactlyOnceInItsOwnFile() throws {
        let dir = StyleCatalog.baseStyleDirectory
        try XCTSkipUnless(FileTools.exists(dir.appendingPathComponent("points")),
                          "no materialized style — run a build first")
        let index = try XCTUnwrap(RuleSetIndex.read(styleDirectory: dir))

        for kind in MapElementKind.allCases {
            let url = dir.appendingPathComponent(kind.ruleFile)
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }

            for meaning in index.all where meaning.kind == kind {
                for rule in meaning.rules {
                    // Contours arrive through an include, so their text is in another file.
                    guard text.contains(rule.condition) else { continue }
                    let found = RuleSetIndex.occurrences(of: rule.raw, in: text)
                    XCTAssertGreaterThan(found, 0,
                                         "\(kind) \(meaning.hex): span not found in "
                                         + kind.ruleFile)
                    // kmap's protected-area block re-adds a rule mkgmap's style already has;
                    // a reassignment refuses such a duplicate rather than moving both.
                    if found > 1 {
                        XCTAssertTrue(rule.raw.contains("nature_reserve"),
                                      "\(kind) \(meaning.hex): unexpected duplicate — "
                                      + truncate(rule.raw, to: 70))
                    }
                }
            }
        }
    }
}
