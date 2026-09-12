import XCTest
@testable import kmap

/// Building the catalogue of what can be left off the map, from the rule lines it is
/// applied to. The catalogue is a set of exact lines to substitute, so an entry whose line
/// has drifted hides nothing and only warns.
final class HideableGeneratorTests: XCTestCase {

    private func catalogue(_ points: String) -> String {
        HideableGenerator.catalogue(fromPoints: points).text
    }

    private func entries(_ points: String) -> [String] {
        catalogue(points).split(separator: "\n").filter { $0.hasPrefix("[") }.map(String.init)
    }

    private func rules(_ points: String) -> [String] {
        catalogue(points).split(separator: "\n").filter { $0.hasPrefix("points: ") }.map(String.init)
    }

    // MARK: What is offered

    func testATypedRuleBecomesAnEntry() {
        let made = catalogue("amenity=cafe [0x2a0e resolution 24]\n")
        XCTAssertTrue(made.contains("@@ Amenities"))
        XCTAssertTrue(made.contains("[amenity-cafe] Cafe"))
        XCTAssertTrue(made.contains("tag: amenity=cafe"))
        XCTAssertTrue(made.contains("points: amenity=cafe [0x2a0e resolution 24]"))
    }

    func testSeveralRulesForOneValueAllRideUnderOneEntry() {
        let made = catalogue("""
        amenity=fuel [0x2f01 resolution 24]
        amenity=fuel & fuel:diesel=yes [0x2f16 resolution 23]
        """)
        XCTAssertEqual(entries(made.isEmpty ? "" : """
        amenity=fuel [0x2f01 resolution 24]
        amenity=fuel & fuel:diesel=yes [0x2f16 resolution 23]
        """).count, 1)
        XCTAssertEqual(rules("""
        amenity=fuel [0x2f01 resolution 24]
        amenity=fuel & fuel:diesel=yes [0x2f16 resolution 23]
        """).count, 2)
    }

    func testAValueWithAColonKeepsItInTheTagAndLosesItInTheIdentifier() {
        let made = catalogue("natural=cave:entrance [0x6601 resolution 24]\n")
        XCTAssertTrue(made.contains("[natural-cave-entrance]"))
        XCTAssertTrue(made.contains("tag: natural=cave:entrance"))
    }

    func testEntriesComeOutInOrderOfTheirValue() {
        let made = entries("""
        amenity=zoo [0x1 resolution 24]
        amenity=bank [0x2 resolution 24]
        amenity=cafe [0x3 resolution 24]
        """)
        XCTAssertEqual(made, ["[amenity-bank] Bank", "[amenity-cafe] Cafe", "[amenity-zoo] Zoo"])
    }

    func testCategoriesComeOutInTheOrderTheCatalogueDeclares() {
        let made = catalogue("""
        shop=bakery [0x1 resolution 24]
        amenity=cafe [0x2 resolution 24]
        """)
        let amenities = made.range(of: "@@ Amenities")!
        let shops = made.range(of: "@@ Shops")!
        XCTAssertLessThan(amenities.lowerBound, shops.lowerBound)
    }

    // MARK: What is left alone

    func testACommentAndAnEmptyLineAreNotRules() {
        XCTAssertTrue(entries("# amenity=cafe [0x1 resolution 24]\n\n   \n").isEmpty)
    }

    func testARuleWithNoTypeIsNotOffered() {
        XCTAssertTrue(entries("amenity=cafe {set foo=bar}\n").isEmpty)
    }

    /// A condition that carries on to the next line cannot be removed on its own: the
    /// half left behind would be a rule with no condition.
    func testAConditionThatContinuesIsNotOffered() {
        XCTAssertTrue(entries("amenity=cafe |\n").isEmpty)
    }

    /// Actions other rules read cannot be dropped with the type.
    func testARuleThatSetsTagsIsNotOffered() {
        XCTAssertTrue(entries("amenity=cafe {set cuisine=x} [0x1 resolution 24]\n").isEmpty)
        XCTAssertTrue(entries("amenity=cafe {add mkgmap:foo=1} [0x1 resolution 24]\n").isEmpty)
    }

    /// Actions that only rename are fine -- the rule keeps them and loses its type.
    func testARuleThatOnlyRenamesIsStillOffered() {
        XCTAssertEqual(entries("amenity=prison [0x1 resolution 24 default_name 'Prison']\n").count, 1)
        XCTAssertEqual(entries("natural=peak {name '${ele}'} [0x1 resolution 24]\n").count, 1)
    }

    func testAKeyNoCategoryClaimsIsNotOffered() {
        XCTAssertTrue(entries("boundary=administrative [0x1 resolution 24]\n").isEmpty)
    }

    /// Places are protected: hiding them would leave the map without settlement names.
    func testPlacesAreNeverOffered() {
        XCTAssertTrue(entries("place=town [0x1 resolution 24]\n").isEmpty)
        XCTAssertTrue(HideableGenerator.protectedKeys.contains("place"))
    }

    // MARK: The catalogue kmap ships

    /// Every shipped entry has a Russian name; a value mkgmap renames or adds would otherwise
    /// appear in English in a Russian list.
    func testEveryShippedEntryHasARussianName() {
        let missing = HideableFeature.all
            .filter { HideableNames.features[$0.id] == nil }
            .map(\.id)
        XCTAssertTrue(missing.isEmpty, "no Russian for: \(missing.joined(separator: ", "))")
    }

    func testEveryShippedCategoryHasARussianName() {
        let missing = Set(HideableFeature.all.map(\.category))
            .filter { HideableNames.categories[$0] == nil }
        XCTAssertTrue(missing.isEmpty, "no Russian for: \(missing.joined(separator: ", "))")
    }

    /// The translation table carries nothing for entries that no longer exist.
    func testNothingIsTranslatedThatIsNoLongerOffered() {
        let known = Set(HideableFeature.all.map(\.id))
        let stale = HideableNames.features.keys.filter { !known.contains($0) }
        XCTAssertTrue(stale.isEmpty, "translated but gone: \(stale.sorted().joined(separator: ", "))")
    }
}
