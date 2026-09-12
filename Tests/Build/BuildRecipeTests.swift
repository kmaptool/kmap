import XCTest
@testable import kmap

/// The recipe itself: tile ids, coverage, where a description goes, which labels survive.
final class BuildRecipeTests: RecipeTestCase {

    // MARK: The tile ids

    func testTheTileIdsStartWhereTheFamilyIdSaysTheyDo() {
        // Tile numbers are family x 10000 + n.
        var made = recipe([region("a", "A")])
        made.familyID = 6300
        XCTAssertEqual(made.mapIDBase, 63000001)
        made.familyID = 6301
        XCTAssertEqual(made.mapIDBase, 63010001)
        // The overview map takes the slot before the first tile: unique per family, and
        // numeric, or mkgmap prefixes it "ovm_" and the gmapsupp combiner drops it.
        XCTAssertEqual(made.overviewMapID, 63010000)
        XCTAssertLessThan(made.overviewMapID, made.mapIDBase)
    }

    // MARK: Coverage

    func testTheCoverageIsEveryRegionsGroundTogether() {
        // Elevation and contours read this; the primary region's box alone leaves the rest
        // of a set flat.
        let a = region("a", "A", box: BBox(minLon: 5, minLat: 49, maxLon: 6, maxLat: 50))
        let b = region("b", "B", box: BBox(minLon: 8, minLat: 47, maxLon: 9, maxLat: 48))
        XCTAssertEqual(recipe([a, b]).coverage,
                       BBox(minLon: 5, minLat: 47, maxLon: 9, maxLat: 50))
    }

    func testARegionWithNoOutlineDoesNotDragTheCoverageToInfinity() {
        let a = region("a", "A", box: BBox(minLon: 5, minLat: 49, maxLon: 6, maxLat: 50))
        let empty = region("b", "B")
        XCTAssertEqual(recipe([a, empty]).coverage,
                       BBox(minLon: 5, minLat: 49, maxLon: 6, maxLat: 50))
    }

    func testElevationIsNeededForEitherPurpose() {
        var made = recipe([region("a", "A")])
        made.contours = false; made.demLayer = false
        XCTAssertFalse(made.needsElevationData)
        made.contours = true
        XCTAssertTrue(made.needsElevationData)
        made.contours = false; made.demLayer = true
        XCTAssertTrue(made.needsElevationData)
    }

    // MARK: Where a description is put

    func testEachDescriptionCarrierNamesTheTagMkgmapWritesItTo() {
        XCTAssertNil(BuildRecipe.DescriptionCarrier.off.tag)
        // Drawn on the map rather than carried in a field of its own.
        XCTAssertNil(BuildRecipe.DescriptionCarrier.inName.tag)
        XCTAssertEqual(BuildRecipe.DescriptionCarrier.phone.tag, "mkgmap:phone")
        XCTAssertEqual(BuildRecipe.DescriptionCarrier.street.tag, "mkgmap:street")
        XCTAssertEqual(BuildRecipe.DescriptionCarrier.region.tag, "mkgmap:region")
        XCTAssertEqual(BuildRecipe.DescriptionCarrier.postcode.tag, "mkgmap:postal_code")
        for carrier in BuildRecipe.DescriptionCarrier.allCases {
            XCTAssertEqual(BuildRecipe.DescriptionCarrier(rawValue: carrier.rawValue), carrier)
            XCTAssertFalse(carrier.label.isEmpty)
        }
    }

    // MARK: Labels that survive the code page

    func testACyrillicMapWithLocalLabelsFallsBackRatherThanPrintingQuestionMarks() {
        // mkgmap turns every character the code page cannot hold into `?`, so a 1251 map
        // asks for Russian first rather than the local name of whatever it borders.
        var made = recipe([region("border-region", "Border Region")])
        made.codePage = 1251
        made.nameTagList = ""
        XCTAssertEqual(made.effectiveNameTagList, "name:ru,name,int_name,name:en")
    }

    func testAChosenLabelLanguagePassesThroughUntouched() {
        var made = recipe([region("a", "A")])
        made.codePage = 1251
        made.nameTagList = LabelLanguage.english.tagList
        XCTAssertEqual(made.effectiveNameTagList, "name:en,int_name,name")
    }

    func testAWesternMapWithLocalLabelsIsLeftAlone() {
        // No tag order rescues 1252: the local name is the one that does not encode, and
        // English first would relabel the whole map.
        var made = recipe([region("continent/large-region", "Large Region")])
        made.codePage = 1252
        made.nameTagList = ""
        XCTAssertEqual(made.effectiveNameTagList, "")
    }
}
