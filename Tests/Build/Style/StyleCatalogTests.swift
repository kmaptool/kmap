import XCTest
@testable import kmap

/// The rewrites kmap makes to mkgmap's own rule set.
final class StyleCatalogTests: XCTestCase {

    // MARK: The volcano badge

    private let defaultPoints = """
    natural=peak {name '${name|def:}${ele|height:m=>ft|def:}'} [0x6616 resolution 24]
    natural=rock [0x6614 resolution 24]
    natural=volcano [0x2c0c resolution 24]
    natural=waterfall [0x6508 resolution 24]
    """

    func testOnlyAnActiveVolcanoKeepsTheBadge() throws {
        let out = try XCTUnwrap(StyleCatalog.volcanoRules(in: defaultPoints))
        XCTAssertTrue(out.contains(
            "natural=volcano & volcano:status=active [0x2c0c resolution 24]"))
        XCTAssertFalse(out.contains("natural=volcano [0x2c0c resolution 24]"),
                       "the catch-all badge rule is still there")
    }

    func testADormantVolcanoFallsThroughToASummit() throws {
        // Rules run in order and the peak rules have already passed, so the summit treatment
        // is restated here, with name and height split into cases to avoid a stray space.
        let out = try XCTUnwrap(StyleCatalog.volcanoRules(in: defaultPoints))
        let lines = out.split(separator: "\n").map(String.init)
        let active = try XCTUnwrap(lines.firstIndex {
            $0.contains("volcano:status=active") })
        let summit = try XCTUnwrap(lines.firstIndex {
            $0.contains("natural=volcano & name=* & ele=*") })
        XCTAssertLessThan(active, summit, "the badge rule must be asked first")
        XCTAssertTrue(out.contains(
            "natural=volcano & name=* & ele=* {name '${name} ${ele}'} [0x6616 resolution 24]"))
        XCTAssertTrue(out.contains("natural=volcano [0x6616 resolution 24]"),
                      "a volcano with no name and no height is still a summit")
    }

    func testTheRestOfTheRuleSetIsLeftAlone() throws {
        let out = try XCTUnwrap(StyleCatalog.volcanoRules(in: defaultPoints))
        XCTAssertTrue(out.contains("natural=rock [0x6614 resolution 24]"))
        XCTAssertTrue(out.contains("natural=waterfall [0x6508 resolution 24]"))
        XCTAssertTrue(out.contains("natural=peak {name"))
    }

    func testAStyleWithoutTheVolcanoLineIsNotTouched() {
        XCTAssertNil(StyleCatalog.volcanoRules(in: "natural=peak [0x6616 resolution 24]"))
        XCTAssertNil(StyleCatalog.volcanoRules(in: ""))
    }

    func testTheShiftedFormIsHandledToo() throws {
        // The POI zoom shift moves point rules from 24 to 22, and may run before this patch.
        let shifted = "natural=volcano [0x2c0c resolution 22]\n"
        let out = try XCTUnwrap(StyleCatalog.volcanoRules(in: shifted))
        XCTAssertTrue(out.contains(
            "natural=volcano & volcano:status=active [0x2c0c resolution 22]"))
    }

    func testTheHideableCatalogueStillNamesALineThatExists() throws {
        // Hiding works by exact substitution in the rule text, so the entry must name a line
        // this rewrite emits.
        let entry = try XCTUnwrap(HideableFeature.feature(id: "natural-volcano"))
        let out = try XCTUnwrap(StyleCatalog.volcanoRules(in: defaultPoints))
        for substitution in entry.substitutions {
            XCTAssertTrue(out.contains(substitution.old),
                          "the hideable entry names a rule the style no longer holds")
        }
    }

    // MARK: The overview diet

    private let coarseRules = """
    landuse=forest | landuse=wood [0x50 resolution 18]
    natural=wood [0x50 resolution 18]
    natural=scree | natural=shingle [0x54 resolution 18]
    natural=scrub [0x4f resolution 18]
    natural=grassland | landuse=meadow & natural=grassland [0x55 resolution 18]
    leisure=nature_reserve [0x16 resolution 18]
    natural=water [0x3c resolution 18]
    waterway=river [0x1f resolution 18]
    highway=trunk [0x02 road_class=4 road_speed=5 resolution 18]
    """

    func testTheGreeneryMovesOffTheTenKilometreZoom() {
        // Nine moves for six rules: the wooded ones move twice, off 18 with the rest of the
        // greenery and again off 19 to the rung the paths arrive on.
        let out = StyleCatalog.overviewDiet(in: coarseRules, cyrillic: true)
        XCTAssertEqual(out.moved, 9)
        XCTAssertTrue(out.text.contains("natural=scree | natural=shingle [0x54 resolution 19]"))
        XCTAssertTrue(out.text.contains("waterway=river [0x1f resolution 19]"))
        XCTAssertFalse(out.text.contains("0x50 resolution 18]"))
    }

    /// The wooded textures wait for resolution 22, the rung the paths appear on, while the
    /// floor keeps the wood's colour at every coarser zoom.
    func testTheWoodedTexturesWaitForThePaths() {
        let out = StyleCatalog.overviewDiet(in: coarseRules, cyrillic: true)
        XCTAssertTrue(out.text.contains("landuse=forest | landuse=wood [0x50 resolution 22]"))
        XCTAssertTrue(out.text.contains("natural=wood [0x50 resolution 22]"))
        XCTAssertTrue(out.text.contains("natural=scrub [0x4f resolution 22]"))
        XCTAssertFalse(out.text.contains("0x50 resolution 19]"))
        XCTAssertFalse(out.text.contains("0x4f resolution 19]"))
    }

    func testWhatTheUserAskedToKeepIsKept() {
        let out = StyleCatalog.overviewDiet(in: coarseRules, cyrillic: true)
        XCTAssertTrue(out.text.contains("leisure=nature_reserve [0x16 resolution 18]"))
        XCTAssertTrue(out.text.contains("natural=water [0x3c resolution 18]"))
        XCTAssertTrue(out.text.contains("highway=trunk [0x02 road_class=4 road_speed=5 resolution 18]"))
    }

    func testAStyleWithoutTheseRulesIsLeftAlone() {
        let out = StyleCatalog.overviewDiet(in: "natural=peak [0x6616 resolution 24]", cyrillic: true)
        XCTAssertEqual(out.moved, 0)
        XCTAssertEqual(out.text, "natural=peak [0x6616 resolution 24]")
    }

    // MARK: Roads for the overview submap

    func testTheFarRoadsComeDownToWhereTheOverviewCanCarryThem() {
        // The overview submap can only carry what the rule set admits at resolutions 15,
        // 14 and 13.
        let rules = """
        highway=motorway & mkgmap:fast_road=yes [0x01 road_class=4 road_speed=7 resolution 14]
        highway=motorway [0x01 road_class=4 road_speed=7 resolution 15]
        highway=trunk & mkgmap:fast_road=yes [0x02 road_class=4 road_speed=5 resolution 15]
        highway=trunk [0x02 road_class=4 road_speed=5 resolution 18]
        highway=primary & mkgmap:fast_road=yes [0x03 road_class=4 road_speed=4 resolution 17]
        highway=primary [0x03 road_class=3 road_speed=4 resolution 19]
        highway=secondary [0x04 road_class=2 road_speed=3 resolution 20]
        boundary=national [0x1e resolution 17]
        """
        let out = StyleCatalog.farRoads(in: rules)
        XCTAssertEqual(out.moved, 7)
        XCTAssertTrue(out.text.contains("boundary=national [0x1e resolution 14]"))
        XCTAssertTrue(out.text.contains("highway=trunk [0x02 road_class=4 road_speed=5 resolution 15]"))
        XCTAssertTrue(out.text.contains("highway=primary [0x03 road_class=3 road_speed=4 resolution 16]"))
        XCTAssertTrue(out.text.contains("resolution 13]"))
        // Secondary roads stay: the far zooms carry roads between towns, not within them.
        XCTAssertTrue(out.text.contains("highway=secondary [0x04 road_class=2 road_speed=3 resolution 20]"))
    }

    // MARK: Restricted ground

    func testTheMilitaryZonesRiseToTheResolutionTheReservesAreDrawnAt() {
        let rules = """
        landuse=military [0x04 resolution 19]
        military=airfield [0x04 resolution 20]
        military=barracks [0x04 resolution 23]
        military=danger_area [0x11 resolution 20]
        military=range [0x04 resolution 20]
        """
        let out = StyleCatalog.restrictedMilitary(in: rules)
        XCTAssertEqual(out.moved, 3)
        XCTAssertTrue(out.text.contains("landuse=military [0x04 resolution 18]"))
        XCTAssertTrue(out.text.contains("military=danger_area [0x11 resolution 18]"))
        XCTAssertTrue(out.text.contains("military=range [0x04 resolution 18]"))
        // A building is not a zone: facility rules keep their own resolutions.
        XCTAssertTrue(out.text.contains("military=airfield [0x04 resolution 20]"))
        XCTAssertTrue(out.text.contains("military=barracks [0x04 resolution 23]"))
    }

    func testTheRestrictedGroundIsDrawnFromTheSameZoomAsTheConservationGround() {
        // Fill and outline both start at the resolution the reserves use; an outline that
        // arrives after its own fill reads as a rendering fault.
        let fills = StyleCatalog.restrictedMilitary(
            in: "landuse=military [0x04 resolution 19]").text
        XCTAssertTrue(fills.contains("resolution 18]"))
        XCTAssertTrue(StyleCatalog.militaryEdgeRules.contains(
            "landuse=military {set kmap:mil_edge=yes} [0x2d resolution 18 continue with_actions]"))
        XCTAssertTrue(StyleCatalog.militaryEdgeRules.contains(
            "military=danger_area & kmap:mil_edge!=* {set kmap:mil_edge=yes} [0x2d resolution 18 continue with_actions]"))
        XCTAssertTrue(StyleCatalog.militaryEdgeRules.contains(
            "military=range & kmap:mil_edge!=* {set kmap:mil_edge=yes} [0x2d resolution 18 continue with_actions]"))
        // The facilities keep their own, later, zooms.
        XCTAssertTrue(StyleCatalog.militaryEdgeRules.contains("military=barracks")
                      && StyleCatalog.militaryEdgeRules.contains("resolution 23"))
    }

    func testTheOverviewOwnsEveryBandFromSixteenBitsUp() {
        // A re-render costs once per map holding data at the coarse bits, so those bands
        // belong to the overview map alone.
        XCTAssertEqual(LevelsProfile.smooth.overviewLevels, "7:16, 8:15, 9:14, 10:13")
        XCTAssertFalse(LevelsProfile.smooth.levels.contains("16"),
                       "bits 16 is back on the tiles, which is the stall we removed")
    }

    func testTheCombinedLadderKeepsStrictlyDecreasingBits() {
        // mkgmap rejects a build where a level is not coarser than the one before it, and
        // the two halves of the ladder are written as separate strings.
        let both = LevelsProfile.smooth.levels + ", " + LevelsProfile.smooth.overviewLevels
        let rungs = both.split(separator: ",").map { rung -> (Int, Int) in
            let pair = rung.split(separator: ":").map { Int($0.trimmingCharacters(in: .whitespaces))! }
            return (pair[0], pair[1])
        }
        XCTAssertEqual(rungs.map(\.0), Array(0...(rungs.count - 1)), "level numbers must run 0,1,2,...")
        for (a, b) in zip(rungs, rungs.dropFirst()) {
            XCTAssertGreaterThan(a.1, b.1, "level \(b.0) is not coarser than level \(a.0)")
        }
        XCTAssertLessThanOrEqual(LevelsProfile.smooth.levelCount, 8, "mkgmap allows at most 8 tile levels")
    }

    // MARK: No decoration on a routable code

    func testNoAddedLineRuleUsesAFirmwareRoutableTypeWithoutBeingARoad() {
        // Garmin firmware may route along the types in GType.isSpecialRoutableLineType, so
        // a non-routable decoration must not use one; 0x2d is the deliberate exception.
        let special = Set(0x01...0x13).union([0x16, 0x1a, 0x1b, 0x2c, 0x2d, 0x2e, 0x2f])
        let allowed: Set<Int> = [0x2d]
        let ruleTexts = [
            "man_made=cutline [0x23 resolution 21]",
            "natural=valley & name=* { name '${name}' } [0x24 resolution 20]",
            StyleCatalog.militaryEdgeRules,
        ].joined(separator: "\n")
        for piece in ruleTexts.components(separatedBy: "[0x").dropFirst() {
            let hex = piece.prefix { $0.isHexDigit }
            guard let code = Int(hex, radix: 16), code <= 0xFF else { continue }
            if special.contains(code) {
                XCTAssertTrue(allowed.contains(code),
                              "0x\(String(code, radix: 16)) is firmware-routable and not a road")
            }
        }
    }


    // MARK: The climber badge

    private let centreRule = "leisure=sports_center | leisure=sports_centre "
        + "{name '${name} (${sport})' | '${sport}'} [0x2d0a resolution 24]"

    func testEverythingPurelyClimbingWearsTheClimberBadge() throws {
        // The stock rule asks only about leisure, so a purely climbing venue would take the
        // sports-centre badge.
        let out = try XCTUnwrap(StyleCatalog.climbingRules(in: centreRule, cyrillic: true))
        let climbing = try XCTUnwrap(out.range(of: "sport=climbing & leisure=sports_centre"))
        let centre = try XCTUnwrap(out.range(of: "leisure=sports_center | leisure=sports_centre"))
        XCTAssertLessThan(climbing.lowerBound, centre.lowerBound,
                          "the sports-centre rule would catch every climbing gym first")
        for rule in ["climbing=crag", "(climbing=route | climbing=route_bottom)",
                     "(climbing=area | climbing=boulder | climbing=yes)"] {
            XCTAssertTrue(out.contains(rule), rule)
        }
        XCTAssertTrue(out.contains("[0x2c0e resolution 24]"))
    }

    func testTheShiftedSportsCentreIsHandledToo() throws {
        // The POI zoom shift moves the rule to 22 before this patch may run.
        let shifted = centreRule.replacingOccurrences(of: "resolution 24", with: "resolution 22")
        let out = try XCTUnwrap(StyleCatalog.climbingRules(in: shifted, cyrillic: true))
        XCTAssertTrue(out.contains("sport=climbing & name!=* { name 'Скалолазание' } [0x2c0e resolution 22]"))
    }

    func testAStyleWithoutTheSportsCentreRuleIsNoticed() {
        XCTAssertNil(StyleCatalog.climbingRules(in: "natural=peak [0x6616 resolution 24]", cyrillic: true))
    }

    /// Whether a TYP draws 0x2c0e is a fact about that TYP, and kmap ships none; only the
    /// rule-set half is checked here.
    func testTheBlanketClimbingLabelIsGone() {
        // The typed rules carry their own default names; a blanket label would outrank them.
        XCTAssertFalse(StyleAssets.russianLabels.contains("sport=climbing|"),
                       "the blanket label is back and will outrank the rule defaults")
    }


    // MARK: The icon repairs

    func testEveryAuditVerdictLandsOnTheStyle() {
        // The sample is shaped as the materialized style holds it; repairs match by prefix.
        let sample = """
        amenity=telephone [0x2f12 resolution 22 default_name 'Телефон']
        amenity=emergency_phone [0x2f12 resolution 22 default_name 'Экстренный телефон']
        historic=memorial [0x2c02 resolution 22]
        amenity=recycling [0x2f15 resolution 22 default_name 'Приём вторсырья']
        amenity=taxi [0x2f17 resolution 22]
        amenity=charging_station [0x2f01 resolution 22 default_name 'Зарядная станция']
        amenity=ferry_terminal [0x2f08 resolution 22]
        amenity=arts_centre [0x2c04 resolution 22]
        shop=furniture [0x2e09 resolution 22]
        shop=boat [0x2f09 resolution 22]
        """
        let out = StyleCatalog.repairIcons(in: sample, cyrillic: true)
        XCTAssertEqual(out.missed, [])
        XCTAssertTrue(out.text.contains("amenity=telephone [0x2f18 "))
        XCTAssertTrue(out.text.contains("amenity=emergency_phone [0x2f16 "))
        XCTAssertTrue(out.text.contains("historic=memorial [0x2c12 "))
        XCTAssertTrue(out.text.contains("amenity=recycling [0x661a "))
        XCTAssertTrue(out.text.contains("amenity=taxi [0x2f19 "))
        XCTAssertTrue(out.text.contains("amenity=charging_station [0x2f1a "))
        XCTAssertTrue(out.text.contains("amenity=ferry_terminal [0x2f09 "))
        XCTAssertTrue(out.text.contains("amenity=arts_centre [0x2d01 "))
        XCTAssertTrue(out.text.contains("shop=furniture [0x2e0c "))
        XCTAssertTrue(out.text.contains("shop=boat [0x2e0c "))
        XCTAssertTrue(out.text.contains("aerialway=station"), "the lift stations ride in with the repairs")
    }

    func testTheRedirectBornRulesCarryTheAnchorAtTheirSource() {
        // These rules come from redirects.txt and are applied after the repair pass, so the
        // corrected code has to be written at their source.
        XCTAssertTrue(StyleAssets.iconRedirects.contains("+ amenity=prison [0x661a "))
        XCTAssertTrue(StyleAssets.iconRedirects.contains("+ amenity=conference_centre [0x661a "))
        XCTAssertTrue(StyleAssets.iconRedirects.contains("+ amenity=convention_center [0x661a "))
    }

    func testTheLiftStationsLandBeforeTheFinalizeSection() {
        // A typed rule inside <finalize> is a style error that fails the compile.
        let sample = "amenity=taxi [0x2f17 resolution 22]\n\n<finalize>\nname\n</finalize>\n"
        let out = StyleCatalog.repairIcons(in: sample, cyrillic: true).text
        let station = out.range(of: "aerialway=station")!
        let finalize = out.range(of: "<finalize>")!
        XCTAssertLessThan(station.lowerBound, finalize.lowerBound,
                          "the stations were appended into <finalize> and killed the compile")
        // The modern emergency=phone spelling rides the same insertion; the stock rule
        // knows only the deprecated amenity=emergency_phone.
        let sos = out.range(of: "emergency=phone [0x2f16 ")!
        XCTAssertLessThan(sos.lowerBound, finalize.lowerBound)
    }

    func testARepairAlreadyAppliedIsNotAMiss() {
        let once = StyleCatalog.repairIcons(in: "amenity=taxi [0x2f19 resolution 22]", cyrillic: true).missed
        XCTAssertFalse(once.contains("taxi off the bus"))
    }

    /// A rule emitting a code the chosen TYP does not style falls back to the receiver's own
    /// icon; kmap ships no TYP, so only the rule set is checked here.
    func testTheRepairTargetsAreTheCodesTheAuditSettledOn() {
        // The redirect strips the stock sport=airport rule and adds nothing back; such
        // places draw through their aeroway tags instead.
        XCTAssertFalse(StyleAssets.iconRedirects.contains("+ sport=airport"),
                       "the aeroplane rule is back")
        XCTAssertTrue(StyleAssets.iconRedirects.contains("- sport=airport"),
                      "the stock rule would leak through unstripped")
    }

    func testACommentEndsAMinusRunInsteadOfJoiningEntries() throws {
        // Prose between entries ends a run of `-` lines; only adjacent `-` lines form one
        // multi-line anchor.
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("kmap-subst-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let points = dir.appendingPathComponent("points")
        try """
        sport=airport [0x2d0b resolution 24]
        amenity=prison [0x3007 resolution 24]
        two=lines [0x10 resolution 24]
            [0x11 resolution 22]
        """.write(to: points, atomically: true, encoding: .utf8)

        let sheet = """
        @@ points
        - sport=airport [0x2d0b resolution 24]

        # prose between entries
        - amenity=prison [0x3007 resolution 24]
        + amenity=prison [0x661a resolution 24]
        - two=lines [0x10 resolution 24]
        -     [0x11 resolution 22]
        + two=lines [0x12 resolution 24]
        """
        let result = try StyleCatalog.applySubstitutions(sheet, in: dir)
        XCTAssertEqual(result.missed, [])
        XCTAssertEqual(result.applied, 3)
        let text = try String(contentsOf: points, encoding: .utf8)
        XCTAssertFalse(text.contains("sport=airport"), "a - with no + deletes the rule")
        XCTAssertTrue(text.contains("amenity=prison [0x661a resolution 24]"))
        XCTAssertTrue(text.contains("two=lines [0x12 resolution 24]"))
        XCTAssertFalse(text.contains("[0x11 resolution 22]"),
                       "adjacent - lines are still one two-line anchor")
    }

    func testAerialwaysAreDrawnAndNeverRoutable() {
        for cyrillic in [true, false] {
            let rules = StyleCatalog.aerialwayLineRules(cyrillic: cyrillic)
            XCTAssertTrue(rules.contains("aerialway=cable_car"))
            XCTAssertTrue(rules.contains("aerialway=chair_lift"))
            XCTAssertTrue(rules.contains("aerialway=t-bar"))
            XCTAssertFalse(rules.contains("road_class"), "nobody walks a cableway")
            // 0x25 sits outside the firmware-routable set, so a lift crossing a path
            // cannot confuse the router.
            XCTAssertTrue(rules.contains("[0x25 "))
        }
    }

    func testEveryInventedLabelFollowsTheMapsLanguage() {
        // An unnamed lift on an English build must not come out labelled in Russian.
        let english = StyleCatalog.aerialwayLineRules(cyrillic: false)
        XCTAssertTrue(english.contains("name 'Cable car'"), english)
        XCTAssertFalse(english.range(of: "[а-яА-Я]", options: .regularExpression) != nil,
                       "Cyrillic label on a non-Cyrillic build")
        let russian = StyleCatalog.aerialwayLineRules(cyrillic: true)
        XCTAssertTrue(russian.contains("name 'Канатная дорога'"), russian)

        let climbing = StyleCatalog.climbingRules(
            in: "leisure=sports_center | leisure=sports_centre "
              + "{name '${name} (${sport})' | '${sport}'} [0x2d0a resolution 24]",
            cyrillic: false)
        XCTAssertTrue(climbing?.contains("name 'Climbing gym'") ?? false)
        XCTAssertNil(climbing?.range(of: "[а-яА-Я]", options: .regularExpression))
    }

    func testTheOverviewDietSpeaksBothLanguages() {
        // The diet matches the leaf-type rules verbatim, so it must match whichever
        // language the forest pass wrote them in.
        for cyrillic in [true, false] {
            let written = StyleCatalog.forestTypeRuleLines(cyrillic: cyrillic,
                                                           resolution: 18)
                .joined(separator: "\n")
            let out = StyleCatalog.overviewDiet(in: written, cyrillic: cyrillic)
            // Each rule moves twice: off the ten-kilometre zoom (18 -> 19), then the
            // drawn textures wait for the paths (19 -> 22).
            XCTAssertEqual(out.moved, 12,
                           "the wooded rules were not all moved (cyrillic: \(cyrillic))")
            XCTAssertFalse(out.text.contains("resolution 18]"), out.text)
            XCTAssertTrue(out.text.contains("resolution 22]"), out.text)
        }
    }

}
