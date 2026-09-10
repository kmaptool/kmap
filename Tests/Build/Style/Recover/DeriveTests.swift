import XCTest
@testable import kmap

/// Derivation from hand-built evidence: every judgement call, with no map and no JVM.
final class DeriveTests: XCTestCase {

    /// A miniature rule set on disk, enough to classify roads and one polygon.
    private var rules: DefaultRuleBook!
    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("derive-\(UUID().uuidString.prefix(6))")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        // The railway rule is written as mkgmap writes it, condition and type on separate
        // lines. `[0x16 resolution 24]` and `highway=corridor` repeat: neither anchors alone.
        try """
        highway=trunk [0x02 road_class=4 road_speed=5 resolution 15]
        highway=trunk_link [0x09 road_class=4 road_speed=2 resolution 20]
        highway=residential [0x06 road_class=0 road_speed=2 resolution 22]
        (railway=rail | railway=tram) & !(tunnel=yes)
            [0x14 resolution 22]
        highway=steps
            [0x16 resolution 24]
        highway=corridor
            [0x16 resolution 24]
        highway=corridor
            [0x17 resolution 24]
        natural=cliff {name '${name}'} [0x2b resolution 22]
        (barrier=gate | barrier=bollard) & kmap:on=path
            {add name='${barrier}'} [0x3200 resolution 24]
        """.write(to: folder.appendingPathComponent("lines"), atomically: true, encoding: .utf8)
        try """
        landuse=forest [0x50 resolution 19]
        landuse=forest & leaf_type=needleleaved [0x57 resolution 22]
        landuse=farmland [0x1c resolution 20]
        landuse=military [0x04 resolution 20]
        building=* & building!=no [0x13 resolution 24]
        """.write(to: folder.appendingPathComponent("polygons"), atomically: true, encoding: .utf8)
        // A points file too, so a point code has somewhere to anchor a rule of its own.
        try """
        amenity=fuel [0x2f01 resolution 24]
        tourism=hotel [0x2c01 resolution 24]
        """.write(to: folder.appendingPathComponent("points"), atomically: true,
                  encoding: .utf8)
        rules = DefaultRuleBook.load(from: folder)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: folder)
    }

    /// Witnesses for one foreign code: `count` distinct sources all carrying `tags`.
    private func forCode(_ kind: ElementDumper.Kind, _ type: Int, seed: inout Int64,
                         _ counted: [(tags: [String: String], count: Int)]) -> Evidence.ForCode {
        var out = Evidence.ForCode(kind: kind, type: type)
        for (tags, count) in counted {
            for _ in 0..<count {
                seed += 1
                out.sources[seed] = tags
            }
        }
        out.elements = out.sources.count
        return out
    }

    /// A code's key is its kind and its type in hex, unpadded: `L2`, not `L02`. The evidence
    /// re-keys whatever it is given, so outcomes come back in that form.
    private func derive(_ codes: [String: Evidence.ForCode],
                        ground: [String: Int] = [:],
                        typDefined: [ElementDumper.Kind: Set<Int>] = [:])
        -> StyleRecovery.Report {
        var report = StyleRecovery.Report()
        StyleRecovery.derive(Evidence(codes: codes), into: &report, rules: rules,
                             typDefined: typDefined, ground: ground)
        return report
    }

    func testAForeignCodeRewritesItsRule() {
        var seed: Int64 = 0
        let report = derive(["A52": forCode(.area, 0x52, seed: &seed,
                                            [(["landuse": "forest"], 10)])])
        XCTAssertEqual(report.outcomes["A52"]?.status, .resolved)
        XCTAssertEqual(report.sheet, """
        @@ polygons
        - landuse=forest & leaf_type=needleleaved [0x57 resolution 22]
        + landuse=forest & leaf_type=needleleaved [0x52 resolution 22]
        @@ polygons
        - landuse=forest [0x50 resolution 19]
        + landuse=forest [0x52 resolution 19]
        """)
    }

    func testALayeredStyleStacksContinueLines() {
        // Two codes over the same ways are two layers of one drawing; the seed is wound
        // back so both codes witness the same elements.
        var seed: Int64 = 0
        let casing = forCode(.line, 0x10206, seed: &seed, [(["highway": "residential"], 40)])
        seed = 0
        let fill = forCode(.line, 0x11615, seed: &seed, [(["highway": "residential"], 90)])
        let report = derive(["L10206": casing, "L11615": fill])
        XCTAssertEqual(report.sheet, """
        @@ lines
        - highway=residential [0x06 road_class=0 road_speed=2 resolution 22]
        + highway=residential [0x10206 resolution 22 continue]
        + highway=residential [0x11615 resolution 22 continue]
        + highway=residential [0x06 road_class=0 road_speed=2 resolution 22]
        """, "both their strokes are drawn, and the road underneath still routes")
    }

    /// An extended type does not route, so a road rule aimed at one keeps a routable line
    /// underneath it.
    func testARoadKeepsALineItCanRouteOn() {
        var seed: Int64 = 0
        let report = derive(["L11f16": forCode(.line, 0x11f16, seed: &seed,
                                               [(["highway": "trunk"], 500)])])
        XCTAssertEqual(report.sheet, """
        @@ lines
        - highway=trunk [0x02 road_class=4 road_speed=5 resolution 15]
        + highway=trunk [0x11f16 resolution 15 continue]
        + highway=trunk [0x02 road_class=4 road_speed=5 resolution 15]
        """)
    }

    /// A plain type routes as well as the original, so the rule is re-aimed rather than
    /// layered.
    func testAPlainTypeJustTakesTheRule() {
        var seed: Int64 = 0
        let report = derive(["L0d": forCode(.line, 0x0d, seed: &seed,
                                            [(["highway": "trunk"], 500)])])
        XCTAssertEqual(report.sheet, """
        @@ lines
        - highway=trunk [0x02 road_class=4 road_speed=5 resolution 15]
        + highway=trunk [0x0d road_class=4 road_speed=5 resolution 15]
        """)
    }

    func testACodeCoveringAFamilyClaimsBothRules() {
        // One stroke covering a family: the smaller member still counts.
        var seed: Int64 = 0
        let report = derive(["L10202": forCode(.line, 0x10202, seed: &seed,
                                               [(["highway": "trunk"], 70),
                                                (["highway": "trunk_link"], 20)])])
        XCTAssertEqual(report.outcomes["L10202"]?.status, .resolved)
        XCTAssertTrue(report.sheet.contains("- highway=trunk [0x02"))
        XCTAssertTrue(report.sheet.contains("+ highway=trunk [0x10202"))
        XCTAssertTrue(report.sheet.contains("- highway=trunk_link [0x09"))
        XCTAssertTrue(report.sheet.contains("+ highway=trunk_link [0x10202"))
    }

    /// mkgmap writes some rules over two lines; both lines are read as one rule.
    func testARuleWrittenOverTwoLinesIsStillReAimed() {
        var seed: Int64 = 0
        let report = derive(["L11519": forCode(.line, 0x11519, seed: &seed,
                                               [(["railway": "rail"], 40)])])
        XCTAssertEqual(report.outcomes["L11519"]?.status, .resolved)
        XCTAssertEqual(report.sheet, """
        @@ lines
        - (railway=rail | railway=tram) & !(tunnel=yes)
        -     [0x14 resolution 22]
        + (railway=rail | railway=tram) & !(tunnel=yes)
        +     [0x11519 resolution 22]
        """, "both lines in the anchor, both written back — half a rule left behind is"
             + " what mkgmap calls a stack size of zero")
    }

    func testARuleWhoseConditionRepeatsAnchorsNothing() {
        // Two rules open with the same condition, so a substitution aimed at that line
        // would hit both; no re-aim is offered.
        var seed: Int64 = 0
        let report = derive(["L1161c": forCode(.line, 0x1161c, seed: &seed,
                                               [(["highway": "corridor"], 30)])])
        XCTAssertFalse(report.sheet.contains("highway=corridor [0x17"))
        XCTAssertFalse(report.sheet.contains("- highway=corridor"))
    }

    /// A meaning with no rule to re-aim gets a rule of its own, written above the file's
    /// first rule so the general rules do not answer for it first.
    func testAMeaningWithNoRuleAtAllGetsOneWritten() {
        var seed: Int64 = 0
        let report = derive(["L11518": forCode(.line, 0x11518, seed: &seed,
                                               [(["natural": "ridge"], 277)])])
        XCTAssertEqual(report.outcomes["L11518"]?.status, .resolved)
        XCTAssertTrue(report.sheet.contains("+ natural=ridge [0x11518 resolution"),
                      "the rule is written from the meaning the witnesses agree on")
        // Anchored on the first rule of the file, which is written back below it.
        let rows = report.sheet.split(separator: "\n").map(String.init)
        XCTAssertEqual(rows.first, "@@ lines")
        XCTAssertEqual(rows[1], "- highway=trunk [0x02 road_class=4 road_speed=5 resolution 15]")
        XCTAssertEqual(rows.last, "+ highway=trunk [0x02 road_class=4 road_speed=5 resolution 15]")
    }

    /// A code standing for two meanings gets a rule for each; dropping either would leave
    /// half its elements undrawn.
    func testACodeStandingForTwoMeaningsGetsBothRules() {
        var seed: Int64 = 0
        let report = derive(["A1e": forCode(.area, 0x1e, seed: &seed,
                                            [(["historic": "archaeological_site"], 86),
                                             (["historic": "ruins"], 70)])])
        XCTAssertEqual(report.outcomes["A1e"]?.status, .resolved)
        XCTAssertTrue(report.sheet.contains("+ historic=archaeological_site [0x1e"))
        XCTAssertTrue(report.sheet.contains("+ historic=ruins [0x1e"))
    }

    /// A new rule is anchored on a line the sheet is not already rewriting: substitutions
    /// match whole lines, so a rewritten anchor would never be found.
    func testANewRuleIsNotAnchoredOnALineTheSheetRewrites() {
        var seed: Int64 = 0
        let report = derive([
            // This code takes the fixture's first rule, so the addition below it must
            // anchor on something else.
            "L11517": forCode(.line, 0x11517, seed: &seed, [(["highway": "trunk"], 60)]),
            "L11518": forCode(.line, 0x11518, seed: &seed, [(["natural": "ridge"], 277)]),
        ])
        XCTAssertTrue(report.sheet.contains("+ natural=ridge [0x11518 resolution"))
        let anchors = report.sheet.split(separator: "\n").filter { $0.hasPrefix("- ") }
        XCTAssertEqual(Set(anchors).count, anchors.count,
                       "no line is named by two substitutions")
    }

    /// A rule with an action block is still found by its tag: the braces are not part of
    /// the tag's value.
    func testARuleThatAlsoActsIsStillFoundByItsTag() {
        var seed: Int64 = 0
        let report = derive(["L11518": forCode(.line, 0x11518, seed: &seed,
                                               [(["natural": "cliff"], 300)])])
        XCTAssertEqual(report.sheet, """
        @@ lines
        - natural=cliff {name '${name}'} [0x2b resolution 22]
        + natural=cliff {name '${name}'} [0x11518 resolution 22]
        """, "re-aimed, not written again as a rule we supposedly lacked")
    }

    /// mkgmap writes the actions and the type together on a rule's second line; that line
    /// is part of the rule, not a condition of its own.
    func testATypeLineThatOpensWithActionsIsStillPartOfItsRule() {
        var seed: Int64 = 0
        let report = derive(["L1207": forCode(.line, 0x1207, seed: &seed,
                                              [(["barrier": "gate"], 200)])])
        XCTAssertEqual(report.sheet, """
        @@ lines
        - (barrier=gate | barrier=bollard) & kmap:on=path
        -     {add name='${barrier}'} [0x3200 resolution 24]
        + (barrier=gate | barrier=bollard) & kmap:on=path
        +     {add name='${barrier}'} [0x1207 resolution 24]
        """)
    }

    /// A code whose witnesses share a key but no single value is read as the family's mark:
    /// the sheet re-aims the members it is sure of and leaves the tail.
    func testAFamilyMarkIsReadByItsKey() {
        var seed: Int64 = 0
        let report = derive(["L11f00": forCode(.line, 0x11f00, seed: &seed,
                                               [(["highway": "trunk"], 10),
                                                (["highway": "trunk_link"], 2),
                                                (["highway": "residential"], 2),
                                                (["highway": "steps"], 2)])])
        XCTAssertEqual(report.outcomes["L11f00"]?.status, .resolved)
        XCTAssertTrue(report.sheet.contains("+ highway=trunk [0x11f00"),
                      "the member it is sure of")
        XCTAssertFalse(report.sheet.contains("+ highway=trunk_link"),
                       "two sightings do not re-aim a rule, family or no family")
    }

    /// Two keys at half the witnesses each is a disagreement, not a family.
    func testTwoHalfFamiliesAreStillMixed() {
        var seed: Int64 = 0
        let report = derive(["L11f00": forCode(.line, 0x11f00, seed: &seed,
                                               [(["highway": "trunk"], 8),
                                                (["highway": "trunk_link"], 2),
                                                (["railway": "rail"], 7),
                                                (["highway": "residential"], 2)])])
        XCTAssertEqual(report.outcomes["L11f00"]?.status, .mixed)
        XCTAssertEqual(report.sheet, "")
    }

    /// A number carries no meaning of its own. Ours for a fuel station and theirs for
    /// an information board can be the same number by accident, and then their picture
    /// lands on our rule — an `i` on every ford. Their map having brushed past the rule
    /// once does not save it: nothing was found that draws what the rule means, so the
    /// rule draws nothing, and the map ports what its author drew.
    func testARuleLeftOnANumberTheirMapMeansOtherwiseIsSilenced() {
        var seed: Int64 = 0
        let report = derive([
            "P2f01": forCode(.point, 0x2f01, seed: &seed,
                             [(["tourism": "information"], 60)]),
            // Another code brushed past a fuel station four times: the chain counts as
            // witnessed, and used to be spared for it — though four of nine hundred
            // fuel stations claims nothing.
            "P2c01": forCode(.point, 0x2c01, seed: &seed,
                             [(["tourism": "hotel"], 2000), (["amenity": "fuel"], 4)]),
        ], ground: ["amenity=fuel": 900, "tourism=hotel": 2400,
                    "tourism=information": 100],
           typDefined: [.point: [0x2f01, 0x2c01]])
        XCTAssertTrue(report.sheet.contains("silenced")
                      && report.sheet.contains("- amenity=fuel [0x2f01 resolution 24]"),
                      "their 0x2f01 is an information board, so our fuel rule draws nothing")
    }

    /// A number their TYP does not paint has no picture at all in their style, and the
    /// receiver would fall back on its own — a look neither map has. The rule draws
    /// nothing, and the user can give the style a picture for it later if they want one.
    func testARuleOnANumberTheirStyleNeverPaintsDrawsNothing() {
        var seed: Int64 = 0
        let report = derive([
            "P2c01": forCode(.point, 0x2c01, seed: &seed, [(["tourism": "hotel"], 90)]),
        ], typDefined: [.point: [0x2c01]])
        XCTAssertTrue(report.sheet.contains("- amenity=fuel [0x2f01 resolution 24]"),
                      "their style paints no 0x2f01, so our fuel rule has no picture")
    }

    /// With no TYP to read there is no vocabulary to port, and nothing is silenced.
    func testAMapWithoutATypSilencesNothing() {
        var seed: Int64 = 0
        let report = derive([
            "P2c01": forCode(.point, 0x2c01, seed: &seed, [(["tourism": "hotel"], 90)]),
        ])
        XCTAssertFalse(report.sheet.contains("silenced"))
    }

    /// Their gate icon was seen a handful of times over a pedestrian crossing — a gate
    /// stands near one — and nothing else drew crossings, so leading the tag alone would
    /// put a gate on every crossing in the map. A style that draws a thing draws most of
    /// them, and the ground says how many there were to draw.
    func testAHandfulOutOfThousandsIsNotAMeaning() {
        var seed: Int64 = 0
        let report = derive(["P1210": forCode(.point, 0x1210, seed: &seed, [
            (["barrier": "lift_gate"], 400),
            (["highway": "crossing"], 8),
        ])], ground: ["barrier=lift_gate": 900, "highway=crossing": 3500])
        XCTAssertTrue(report.sheet.contains("barrier=lift_gate"),
                      "what the code is really for still earns its rule")
        XCTAssertFalse(report.sheet.contains("highway=crossing"),
                       "eight of three and a half thousand is the matcher brushing past")
    }

    /// The same handful, where that is all there was to draw, is the whole meaning.
    func testAHandfulOutOfAHandfulIsAMeaning() {
        var seed: Int64 = 0
        let report = derive(["P1211": forCode(.point, 0x1211, seed: &seed, [
            (["barrier": "lift_gate"], 400),
            (["amenity": "photo_booth"], 8),
        ])], ground: ["barrier=lift_gate": 900, "amenity=photo_booth": 9])
        XCTAssertTrue(report.sheet.contains("amenity=photo_booth"),
                      "eight of nine is how a style draws a rare thing")
    }

    /// With nothing known about the ground, the claim is judged as it was before.
    func testAnUncountedGroundLeavesTheJudgementAsItWas() {
        var seed: Int64 = 0
        let report = derive(["P1212": forCode(.point, 0x1212, seed: &seed, [
            (["barrier": "lift_gate"], 400),
            (["highway": "crossing"], 8),
        ])])
        XCTAssertTrue(report.sheet.contains("highway=crossing"))
    }

    func testARuleIsNotInventedFromOneSighting() {
        var seed: Int64 = 0
        let report = derive(["L10f15": forCode(.line, 0x10f15, seed: &seed,
                                               [(["aerialway": "yes"], 1)])])
        XCTAssertEqual(report.outcomes["L10f15"]?.status, .singleWitness)
        XCTAssertEqual(report.sheet, "")
    }

    /// Two codes over the same meaning but different elements are not layers: the busier
    /// code takes the rule and the other is not stacked on top of it.
    func testTwoCodesOverDifferentElementsAreNotLayers() {
        var seed: Int64 = 0
        let report = derive([
            "L11f12": forCode(.line, 0x11f12, seed: &seed, [(["highway": "path"], 30)]),
            "L10e11": forCode(.line, 0x10e11, seed: &seed, [(["highway": "path"], 41)]),
        ])
        XCTAssertFalse(report.sheet.contains("continue"))
        XCTAssertTrue(report.sheet.contains("+ highway=path [0x10e11"))
    }

    /// A meaning belongs to the code that draws most of it; a few stray matches under
    /// another code do not claim it.
    func testAStrayMatchDoesNotClaimAMeaningFromTheCodeThatDrawsIt() {
        var seed: Int64 = 0
        let report = derive([
            "L10e11": forCode(.line, 0x10e11, seed: &seed, [(["highway": "path"], 400)]),
            "L10407": forCode(.line, 0x10407, seed: &seed, [(["railway": "rail"], 170),
                                                            (["highway": "path"], 17)]),
        ])
        XCTAssertEqual(report.outcomes["L10407"]?.status, .resolved)
        XCTAssertTrue(report.sheet.contains("+     [0x10407 resolution 22]"),
                      "the railway rule is re-aimed, since that is what it draws")
        XCTAssertFalse(report.sheet.contains("+ highway=path [0x10407"),
                       "and the strays do not take the path rule with them")
        XCTAssertTrue(report.sheet.contains("+ highway=path [0x10e11"))
    }

    /// A generic mark stands for a whole family, so every member is re-aimed onto it even
    /// where no single meaning holds a majority.
    func testAGenericMarkClaimsTheWholeFamilyItDraws() {
        var seed: Int64 = 0
        let report = derive(["Lf": forCode(.line, 0x0f, seed: &seed,
                                            [(["highway": "trunk"], 40),
                                             (["highway": "trunk_link"], 30),
                                             (["highway": "residential"], 20),
                                             (["railway": "rail"], 10),
                                             (["highway": "steps"], 5)])])
        XCTAssertEqual(report.outcomes["Lf"]?.status, .resolved)
        for member in ["+ highway=trunk [0x0f", "+ highway=trunk_link [0x0f",
                       "+ highway=residential [0x0f", "+ highway=steps"] {
            XCTAssertTrue(report.sheet.contains(member), "\(member) is part of what it draws")
        }
    }

    func testALoneWitnessDoesNotArgueWithACrowd() {
        var seed: Int64 = 0
        let report = derive([
            "L11619": forCode(.line, 0x11619, seed: &seed, [(["highway": "trunk"], 97)]),
            "L11605": forCode(.line, 0x11605, seed: &seed, [(["highway": "trunk"], 1)]),
        ])
        XCTAssertEqual(report.outcomes["L11605"]?.status, .singleWitness)
        XCTAssertFalse(report.sheet.contains("0x11605"))
        XCTAssertTrue(report.sheet.contains("+ highway=trunk [0x11619"))
    }

    func testScatterStaysMixed() {
        // Seen often enough to judge, but no meaning clears the claim floor.
        var seed: Int64 = 0
        let report = derive(["Lf": forCode(.line, 0x0f, seed: &seed,
                                           [(["highway": "trunk"], 2),
                                            (["highway": "trunk_link"], 2),
                                            (["highway": "residential"], 2),
                                            (["railway": "rail"], 2),
                                            (["highway": "steps"], 2)])])
        XCTAssertEqual(report.outcomes["Lf"]?.status, .mixed)
        XCTAssertEqual(report.sheet, "")
    }

    /// The same shape with only a handful of witnesses is reported as too few rather than
    /// as a disagreement.
    func testAHandfulOfSightingsIsSaidToBeAHandful() {
        var seed: Int64 = 0
        let report = derive(["Lf": forCode(.line, 0x0f, seed: &seed,
                                           [(["highway": "trunk"], 2),
                                            (["highway": "residential"], 1)])])
        XCTAssertEqual(report.outcomes["Lf"]?.status, .singleWitness)
        XCTAssertEqual(report.sheet, "")
    }

    /// Where no rule exists for a family, one family rule is written for all of it: a
    /// wildcard catches the long tail of values no floor would let through one by one.
    func testAFamilyWeHaveNoRuleForGetsOneFamilyRule() {
        var seed: Int64 = 0
        let report = derive(["L12207": forCode(.line, 0x12207, seed: &seed,
                                               [(["building": "yes"], 763),
                                                (["building": "house"], 110),
                                                (["building": "residential"], 52)])])
        XCTAssertEqual(report.outcomes["L12207"]?.status, .resolved)
        XCTAssertTrue(report.sheet.contains("+ building=* [0x12207"), report.sheet)
        XCTAssertFalse(report.sheet.contains("+ building=yes [0x12207"), report.sheet)
    }

    /// A side-tag carried by an element describes that element, not a feature of its own,
    /// so no rule is written from it.
    func testASideTagOfSomethingWeDrawGetsNoRuleOfItsOwn() {
        var seed: Int64 = 0
        let report = derive(["A2e": forCode(.area, 0x2e, seed: &seed,
                                            [(["landuse": "forest"], 1380),
                                             (["natural": "coastline"], 78)])])
        XCTAssertEqual(report.outcomes["A2e"]?.status, .resolved)
        XCTAssertTrue(report.sheet.contains("+ landuse=forest [0x2e"))
        XCTAssertFalse(report.sheet.contains("natural=coastline"),
                       "the rule that would have drawn every coast as sand")
    }

    func testAnEvenSplitIsAGeneralizationCodeNotNoise() {
        // A coarse-zoom stroke drawn for several kinds of road claims every one of them.
        var seed: Int64 = 0
        let report = derive(["Lf": forCode(.line, 0x0f, seed: &seed,
                                            [(["highway": "trunk"], 12),
                                             (["highway": "residential"], 9)])])
        XCTAssertEqual(report.outcomes["Lf"]?.status, .resolved)
        XCTAssertTrue(report.sheet.contains("+ highway=trunk [0x0f"))
        XCTAssertTrue(report.sheet.contains("+ highway=residential [0x0f"))
    }

    /// A zoomed-out stroke is measured against nobody, so a handful of sightings at a
    /// coarse zoom would otherwise become the code's ladder and be painted over every
    /// rule closing on it.
    func testAHandfulAtACoarseZoomIsNotAStroke() {
        var seed: Int64 = 0
        var trunk = forCode(.line, 0x02, seed: &seed, [(["highway": "trunk"], 50)])
        for id in trunk.sources.keys { trunk.sourceZoom[id] = 24 }
        trunk.resolutions = [24: 50]
        var brushed = forCode(.line, 0x0f, seed: &seed, [(["highway": "trunk"], 4)])
        for id in brushed.sources.keys { brushed.sourceZoom[id] = 20 }
        brushed.resolutions = [20: 4]
        let report = derive(["L2": trunk, "Lf": brushed])
        XCTAssertFalse(report.sheet.contains("0x0f"), report.sheet)
    }

    /// A substation building and a substation yard share a tag. Their map draws the
    /// buildings as buildings and the yards their own way: the yard code is no stray
    /// of the building code, and its rule leaves the buildings to the building rule.
    func testAYardIsNotAStrayOfTheBuildingsStandingInIt() {
        var seed: Int64 = 0
        let report = derive([
            "A13": forCode(.area, 0x13, seed: &seed,
                           [(["building": "yes"], 300),
                            (["building": "yes", "power": "substation"], 60)]),
            "A25": forCode(.area, 0x25, seed: &seed, [(["power": "substation"], 10)]),
        ])
        XCTAssertEqual(report.outcomes["A25"]?.status, .resolved)
        XCTAssertTrue(report.sheet.contains("+ power=substation & building!=* [0x25"),
                      report.sheet)
    }

    /// A rule of ours that buildings match too is not re-aimed by open ground: the
    /// churchyard gets its own narrowed rule, and the church stays a building.
    func testOpenGroundDoesNotTakeTheBuildingsWithIt() {
        var seed: Int64 = 0
        let report = derive([
            "A13": forCode(.area, 0x13, seed: &seed,
                           [(["building": "yes"], 300),
                            (["building": "yes", "landuse": "military"], 30)]),
            "A36": forCode(.area, 0x36, seed: &seed, [(["landuse": "military"], 15)]),
        ])
        XCTAssertTrue(report.sheet.contains("+ landuse=military & building!=* [0x36"),
                      report.sheet)
        XCTAssertTrue(report.sheet.contains("+ landuse=military & building!=* [0x04"),
                      "our rule keeps the yards, the buildings fall through: " + report.sheet)
        XCTAssertFalse(report.sheet.contains("[0x13 resolution 20]"), report.sheet)
    }

    /// Three mistagged houses do not make the woods a built thing.
    func testAHandfulOfMistaggedBuildingsDoesNotSplitTheWoods() {
        var seed: Int64 = 0
        let report = derive([
            "A13": forCode(.area, 0x13, seed: &seed,
                           [(["building": "yes"], 300),
                            (["building": "yes", "landuse": "forest"], 3)]),
            "A52": forCode(.area, 0x52, seed: &seed, [(["landuse": "forest"], 200)]),
        ])
        XCTAssertTrue(report.sheet.contains("+ landuse=forest [0x52"), report.sheet)
        XCTAssertFalse(report.sheet.contains("building!=*"), report.sheet)
    }

    func testAYardNobodyBuildsOnKeepsAPlainRule() {
        var seed: Int64 = 0
        let report = derive([
            "A25": forCode(.area, 0x25, seed: &seed, [(["power": "substation"], 10)]),
        ])
        XCTAssertTrue(report.sheet.contains("+ power=substation [0x25"), report.sheet)
    }

    /// One sighting at a coarse zoom does not stretch the band down to it.
    func testAZoomSeenOnceIsNotABand() {
        var seed: Int64 = 0
        var yard = forCode(.area, 0x25, seed: &seed, [(["power": "substation"], 10)])
        for (n, id) in yard.sources.keys.sorted().enumerated() {
            yard.sourceZoom[id] = n == 0 ? 18 : 24
        }
        yard.resolutions = [18: 1, 24: 9]
        let report = derive(["A25": yard])
        XCTAssertTrue(report.sheet.contains("[0x25 resolution 24-24]"), report.sheet)
    }

    func testACodeTheRulesAlreadyEmitIsNotForeign() {
        var seed: Int64 = 0
        let report = derive(["L2": forCode(.line, 0x02, seed: &seed,
                                            [(["highway": "trunk"], 50)])])
        XCTAssertEqual(report.outcomes["L2"]?.status, .resolved)
        // Examined rather than waved through: the number being a default code is no
        // promise the foreign style means the same thing by it.
        XCTAssertEqual(report.outcomes["L2"]?.meaning,
                       "highway=trunk ×50 — a default code too")
        XCTAssertEqual(report.sheet, "")
    }

    func testNoEvidenceSaysSo() {
        let report = derive(["P6404": Evidence.ForCode(kind: .point, type: 0x6404)])
        XCTAssertEqual(report.outcomes["P6404"]?.status, .noEvidence)
    }

    /// Two codes over the same new meaning are layered: both rules are written, the first
    /// continuing so the second is reached, in a fixed order when witness counts are equal.
    func testTwoCodesOverTheSameNewMeaningAreLayeredAdditions() {
        var seed: Int64 = 0
        let base = forCode(.line, 0x13, seed: &seed, [(["man_made": "pier"], 131)])
        seed = 0   // the same elements, seen under the other code
        let stroke = forCode(.line, 0x11f11, seed: &seed, [(["man_made": "pier"], 131)])
        let report = derive(["L13": base, "L11f11": stroke])
        let lines = report.sheet.components(separatedBy: "\n").filter { $0.hasPrefix("+ man_made=pier") }
        XCTAssertEqual(lines.count, 2, "sheet:\n\(report.sheet)")
        guard lines.count == 2 else { return }
        XCTAssertTrue(lines[0].hasSuffix("continue]"), "the first of two layers continues: \(lines)")
        XCTAssertFalse(lines[1].contains("continue"))
        XCTAssertTrue(lines[0].contains("[0x13 "), "ties broken by type, lowest first: \(lines)")
    }
}

/// The judgement calls around colliding numbers: a foreign style may use a code the
/// default set also uses, and mean something entirely different by it.
extension DeriveTests {

    private func derive(_ codes: [String: Evidence.ForCode],
                        typDefined: [ElementDumper.Kind: Set<Int>]) -> StyleRecovery.Report {
        var report = StyleRecovery.Report()
        StyleRecovery.derive(Evidence(codes: codes), into: &report,
                             rules: DefaultRuleBook.load(from: folder),
                             typDefined: typDefined)
        return report
    }

    func testACollidingNumberReAimsAChainItDoesNotOwn() {
        // Their 0x1c draws barracks; kmap's 0x1c is farmland. The military rule is
        // re-aimed onto their number, farmland is left to other evidence.
        var seed: Int64 = 0
        let report = derive(["A1C": forCode(.area, 0x1c, seed: &seed,
                                            [(["landuse": "military"], 10)])])
        XCTAssertTrue(report.sheet.contains(
            "+ landuse=military [0x1c resolution 20]"), report.sheet)
    }

    func testAChainFollowsWhatTheMapActuallyDrew() {
        // The map draws every forest as 0x50: the plain rule stands untouched, and the
        // needle line — whose own code the map never uses — follows the map. On a map
        // that does draw 0x57, the witnessed-line guard keeps it instead.
        var seed: Int64 = 0
        let report = derive(["A50": forCode(.area, 0x50, seed: &seed,
                                            [(["landuse": "forest"], 10)])])
        XCTAssertFalse(report.sheet.contains("- landuse=forest [0x50"), report.sheet)
        XCTAssertTrue(report.sheet.contains(
            "+ landuse=forest & leaf_type=needleleaved [0x50 resolution 22]"), report.sheet)
    }

    func testOnlyTheUnwitnessedLinesOfAChainAreReAimed() {
        // Their map draws forest under two numbers: 0x50, which the chain owns, and
        // 0x1c, which it does not. The needle line, whose own 0x57 their map never
        // uses, is re-aimed; the 0x50 line stands because 0x50 was seen drawing this.
        var seed: Int64 = 0
        let report = derive([
            "A50": forCode(.area, 0x50, seed: &seed, [(["landuse": "forest"], 10)]),
            "A1C": forCode(.area, 0x1c, seed: &seed, [(["landuse": "forest"], 10)]),
        ])
        XCTAssertTrue(report.sheet.contains(
            "- landuse=forest & leaf_type=needleleaved [0x57 resolution 22]"), report.sheet)
        XCTAssertFalse(report.sheet.contains("- landuse=forest [0x50"), report.sheet)
    }

    func testARuleTheirTypWouldRepaintIsSilenced() {
        // Their TYP paints 0x1c, their map uses 0x1c for barracks, and nothing was ever
        // seen drawing farmland: the farmland rule would wear barracks over every
        // field, so it is deleted.
        var seed: Int64 = 0
        let report = derive(["A1C": forCode(.area, 0x1c, seed: &seed,
                                            [(["landuse": "military"], 10)])],
                            typDefined: [.area: [0x1c]])
        XCTAssertTrue(report.sheet.contains("- landuse=farmland [0x1c resolution 20]"),
                      report.sheet)
        XCTAssertFalse(report.sheet.contains("+ landuse=farmland"), report.sheet)
    }

    func testNothingIsSilencedWithoutTheirTypDefiningTheCode() {
        // The same evidence, but their TYP has no 0x1c: the receiver would draw its own
        // plain default, which harms nothing, and the rule stays.
        var seed: Int64 = 0
        let report = derive(["A1C": forCode(.area, 0x1c, seed: &seed,
                                            [(["landuse": "military"], 10)])])
        XCTAssertFalse(report.sheet.contains("- landuse=farmland"), report.sheet)
    }

    func testAFamilyRuleAnswersForTagsWithNoRuleOfTheirOwn() {
        // `building=* & building!=no` draws building=yes; a foreign code seen drawing
        // buildings re-aims the family rather than inventing a duplicate rule.
        var seed: Int64 = 0
        let report = derive(["A99": forCode(.area, 0x99, seed: &seed,
                                            [(["building": "yes"], 10)])])
        XCTAssertTrue(report.sheet.contains(
            "+ building=* & building!=no [0x99 resolution 24]"), report.sheet)
        XCTAssertFalse(report.sheet.contains("their style draws building=yes, ours had"
                       + " no rule"), report.sheet)
    }
}

extension DeriveTests {

    /// A code the rule already emits is never also stacked above it: two copies of one
    /// stroke draw thicker and in the wrong colour.
    func testTheRulesOwnCodeIsNotLayeredOverItself() {
        // Their map draws trunks with the plain code the rule already emits AND with an
        // extended stroke of their own.
        var seed: Int64 = 0
        let plain = forCode(.line, 0x02, seed: &seed, [(["highway": "trunk"], 40)])
        seed -= 40
        let stroke = forCode(.line, 0x11f14, seed: &seed, [(["highway": "trunk"], 40)])
        let report = derive(["L2": plain, "L11f14": stroke])
        let sheet = report.sheet
        XCTAssertTrue(sheet.contains("[0x11f14"), sheet)
        XCTAssertEqual(sheet.components(separatedBy: "+ highway=trunk [0x02").count - 1, 1,
                       "the plain code appears once, as the routable line")
    }
}

extension DeriveTests {

    /// A line rule for something our style also draws as an area must continue, or
    /// mkgmap converts the closed way as a line and the fill is lost.
    func testALineAdditionOverAnAreaKeepsLooking() {
        var seed: Int64 = 0
        let report = derive(["L12207": forCode(.line, 0x12207, seed: &seed,
                                               [(["building": "yes"], 400),
                                                (["building": "house"], 90),
                                                (["building": "shed"], 40)])])
        // Banded where the evidence knows the zooms, and `continue` either way: the
        // hand-built evidence here records none, so the rule keeps its typical zoom.
        XCTAssertTrue(report.sheet.contains("+ building=* [0x12207 resolution 22 continue]"),
                      report.sheet)
    }
}
