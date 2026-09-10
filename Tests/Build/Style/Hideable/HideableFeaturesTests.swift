import XCTest
@testable import kmap

/// The list of things a user can leave off the map.
///
/// Hiding rewrites mkgmap's own rule text, so a feature whose `old` no longer matches does
/// nothing. The ids are stored in settings, so renaming one un-hides the user's choice.
final class HideableFeaturesTests: XCTestCase {

    func testTheShippedCatalogueParsesIntoRealEntries() {
        XCTAssertGreaterThan(HideableFeature.all.count, 10)
        for feature in HideableFeature.all {
            XCTAssertFalse(feature.id.isEmpty)
            XCTAssertFalse(feature.name.isEmpty, feature.id)
            XCTAssertFalse(feature.category.isEmpty, feature.id)
            XCTAssertFalse(feature.substitutions.isEmpty, feature.id)
        }
    }

    func testEveryIdIsUniqueOrOneOfThemCannotBeReached() {
        var seen = Set<String>()
        for feature in HideableFeature.all {
            XCTAssertTrue(seen.insert(feature.id).inserted, "\(feature.id) appears twice")
        }
    }

    func testEverySubstitutionActuallyChangesSomething() {
        // A replacement equal to its original reports itself applied and changes nothing.
        for feature in HideableFeature.all {
            for substitution in feature.substitutions {
                XCTAssertNotEqual(substitution.old, substitution.new, feature.id)
                XCTAssertFalse(substitution.old.isEmpty, feature.id)
                XCTAssertFalse(substitution.file.isEmpty, feature.id)
            }
        }
    }

    func testHidingKeepsTheActionsAndDropsOnlyTheGarminType() {
        // A hidden barrier still affects routing, so the replacement keeps the rule's
        // `{...}` actions and loses only its `[0x… ]`.
        for feature in HideableFeature.all where feature.id.hasPrefix("barriers-") {
            for substitution in feature.substitutions {
                XCTAssertTrue(substitution.old.contains("[0x"), feature.id)
                XCTAssertFalse(substitution.new.contains("[0x"), feature.id)
                XCTAssertTrue(substitution.new.contains("{add name="), feature.id)
                XCTAssertTrue(substitution.new.contains("kmap: hidden"), feature.id)
            }
        }
    }

    func testTheGeneratedEntriesCommentTheirRuleOutWhole() {
        let curatedIDs = Set(HideableFeature.all.prefix(4).map(\.id))
        for feature in HideableFeature.all where !curatedIDs.contains(feature.id) {
            for substitution in feature.substitutions {
                XCTAssertTrue(substitution.new.hasPrefix("# "), feature.id)
                XCTAssertTrue(substitution.new.contains(substitution.old), feature.id)
            }
        }
    }

    func testTheBarrierChoicesAreTheOnesSettingsAlreadyHold() {
        // These ids sit in the settings file; renaming one silently un-hides that choice.
        let ids = HideableFeature.all.map(\.id)
        for id in ["barriers-fence", "barriers-minor", "barriers-path", "barriers-other"] {
            XCTAssertTrue(ids.contains(id), "\(id) has gone from the catalogue")
            XCTAssertNotNil(HideableFeature.feature(id: id))
        }
        XCTAssertNil(HideableFeature.feature(id: "no-such-feature"))
    }

    func testTheFourBarrierRulesCoverEveryBarrierBetweenThem() {
        // Three contexts and an "everything else" that must exclude exactly those three.
        let byContext = ["barriers-fence": "kmap:on=fence",
                         "barriers-minor": "kmap:on=minor",
                         "barriers-path": "kmap:on=path"]
        for (id, condition) in byContext {
            let rule = HideableFeature.feature(id: id)!.substitutions[0].old
            XCTAssertTrue(rule.contains(condition), id)
        }
        let other = HideableFeature.feature(id: "barriers-other")!.substitutions[0].old
        for context in ["path", "minor", "fence"] {
            XCTAssertTrue(other.contains("kmap:on!=\(context)"), context)
        }
    }

    /// The hide names the lines the split writes: three groups per context, byte for byte.
    func testTheBarrierHidesNameTheLinesTheSplitWrites() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("barriers-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        try """
        barrier=bollard | barrier=bus_trap | barrier=gate | barrier=block | barrier=cycle_barrier |
            barrier=stile | barrier=kissing_gate | barrier=lift_gate | barrier=swing_gate
            {add name='${barrier|subst:"_=> "}'} [0x3200 resolution 24]
        """.write(to: dir.appendingPathComponent("points"), atomically: true, encoding: .utf8)
        let settings = SettingsStore()
        let catalog = StyleCatalog(settings: settings, toolchain: Toolchain(settings: settings))
        try catalog.splitBarrierRule(in: dir, log: Log())
        let points = try String(contentsOf: dir.appendingPathComponent("points"), encoding: .utf8)
        for feature in HideableFeature.all where feature.id.hasPrefix("barriers-") {
            XCTAssertEqual(feature.substitutions.count, StyleCatalog.barrierGroups.count, feature.id)
            for substitution in feature.substitutions {
                XCTAssertTrue(points.contains(substitution.old), "\(feature.id): \(substitution.old)")
            }
        }
        XCTAssertTrue(points.contains("[0x3201 resolution 24]"), "the boom's own number")
        XCTAssertTrue(points.contains("[0x3202 resolution 24]"), "the bollard's own number")
    }

    func testHidingABarrierAlsoTakesItOutOfTheCustomPOIFile() {
        // The .gpi carries no barrier context, so any barrier choice drops barriers from it
        // wholesale.
        for feature in HideableFeature.all where feature.id.hasPrefix("barriers-") {
            XCTAssertEqual(feature.tag, "barrier=*", feature.id)
        }
    }

    func testTheCategoriesAreInCatalogueOrderWithTheCuratedOnesFirst() {
        let categories = HideableFeature.categories
        XCTAssertEqual(categories.first, "Barriers and gates")
        XCTAssertEqual(Set(categories).count, categories.count, "a category is listed twice")
        XCTAssertEqual(Set(categories), Set(HideableFeature.all.map(\.category)))
    }

    func testTwoEntriesAreTheSameEntryWhenTheirIdsMatch() {
        // The screen compares them to decide what is ticked.
        let a = HideableFeature.feature(id: "barriers-fence")
        XCTAssertEqual(a, HideableFeature.feature(id: "barriers-fence"))
        XCTAssertNotEqual(a, HideableFeature.feature(id: "barriers-path"))
    }
}
