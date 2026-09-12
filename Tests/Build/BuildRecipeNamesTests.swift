import XCTest
@testable import kmap

/// What a build is called: on the receiver, in the .img header and on disk.
final class BuildRecipeNamesTests: RecipeTestCase {

    // MARK: What the map is called

    func testOneRegionKeepsItsOwnName() {
        let made = recipe([region("continent/small-region", "Small Region")])
        XCTAssertEqual(made.mapName, "Small Region")
        XCTAssertEqual(made.slug, "continent-small-region")
    }

    func testASetIsSpelledOutUntilItIsTooLongToBe() {
        let a = region("a", "Region A"), b = region("b", "Region B")
        let c = region("c", "Region C"), d = region("d", "Region D")
        XCTAssertEqual(recipe([a, b]).mapName, "Region A and Region B")
        XCTAssertEqual(recipe([a, b, c]).mapName, "Region A, Region B and Region C")
        XCTAssertEqual(recipe([a, b, c, d]).mapName, "Region A, Region B, Region C and 1 more")
    }

    func testTheSlugOfASetNamesTwoAndCountsTheRest() {
        let a = region("continent/region-a", "A"), b = region("continent/region-b", "B")
        let c = region("continent/region-c", "C"), d = region("continent/region-d", "D")
        XCTAssertEqual(recipe([a, b]).slug, "continent-region-a+continent-region-b")
        XCTAssertEqual(recipe([a, b, c]).slug, "continent-region-a+continent-region-b+1")
        XCTAssertEqual(recipe([a, b, c, d]).slug, "continent-region-a+continent-region-b+2")
    }

    // MARK: What the finished files are called

    func testAFinishedFileNamesTheRegionsThenTheDate() {
        // The date sits immediately before the extension, so builds from one card stay
        // distinguishable. The style and the profile are the folder's business.
        let made = dated(recipe([region("small-region", "Small Region")]))
        XCTAssertEqual(made.fileName(), "kmap-small-region-2026-08-21.img")
        XCTAssertEqual(made.dateStamp, "2026-08-21")
        XCTAssertEqual(dated(recipe([region("region-a", "A"), region("region-b", "B")])).fileName(),
                       "kmap-region-a+region-b-2026-08-21.img")
    }

    func testASetNamesTwoRegionsAndCountsTheRest() {
        let made = dated(recipe([region("a", "A"), region("b", "B"), region("c", "C")]))
        XCTAssertEqual(made.fileName(), "kmap-a+b+1-more-2026-08-21.img")
        // Two ids that do not fit leave one, and the count grows to match.
        let three = dated(recipe([region("crimean-fed-district", "Crimea"),
                                  region("north-caucasus-fed-district", "Caucasus"),
                                  region("south-fed-district", "South")]))
        XCTAssertEqual(three.fileName(), "kmap-crimean-fed-district+2-more-2026-08-21.img")
    }

    func testEveryPieceOfASplitMapNamesItsPlaceBeforeTheDate() {
        let made = dated(recipe([region("continent/large-region", "Large Region")]))
        XCTAssertEqual(made.fileName(ordinal: 1, of: 3),
                       "kmap-continent-large-region-p1-2026-08-21.img")
        XCTAssertEqual(made.fileName(ordinal: 3, of: 3),
                       "kmap-continent-large-region-p3-2026-08-21.img")
        // A single file carries no part marker at all.
        XCTAssertEqual(made.fileName(ordinal: 1, of: 1),
                       "kmap-continent-large-region-2026-08-21.img")
    }

    // MARK: What the map says about itself

    func testTheAttributionCarriesOpenStreetMapAndKmapBoth() {
        // The OSM licence must be carried, and the build line names what produced the map.
        let made = dated(recipe([region("a", "A")]))
        let lines = made.copyrightLines
        XCTAssertGreaterThanOrEqual(lines.count, 2, "mkgmap keeps the first line off the device")
        XCTAssertTrue(lines.contains { $0.contains("OpenStreetMap") && $0.contains("ODbL") })
        XCTAssertTrue(lines.contains { $0.contains("Built by kmap \(Version.number)")
                                    && $0.contains("2026-08-21") })
    }

    func testTheAttributionIsWrittenInTheAlphabetADeviceCanStore() {
        // Labels are held in a six-bit alphabet: the first character it does not know
        // silently drops the rest of the line.
        var made = dated(recipe([region("a", "A")]))
        made.contours = true
        made.demLayer = true
        made.demSources = "view1,view3"
        for line in made.copyrightLines {
            XCTAssertTrue(line.allSatisfy { $0.isASCII }, line)
            for forbidden in ["·", "—", "–", "©", "\t"] {
                XCTAssertFalse(line.contains(forbidden), "\(line) holds \(forbidden)")
            }
        }
    }

    func testTheElevationLineOnlyAppearsWhenThereIsElevation() {
        var made = dated(recipe([region("a", "A")]))
        made.contours = false
        made.demLayer = false
        XCTAssertFalse(made.copyrightLines.contains { $0.hasPrefix("Elevation:") })
        made.demLayer = true
        XCTAssertTrue(made.copyrightLines.contains { $0.hasPrefix("Elevation:") })
    }

    // MARK: What fits in an img header

    func testTheHeaderDescriptionNeverReachesGarminsLimit() {
        // mkgmap rejects a description past 50 characters, and only once every tile is
        // compiled.
        var made = dated(recipe([region("neighbour-region", "Neighbour Region"),
                                 region("antimeridian-region", "Antimeridian Region"),
                                 region("small-region", "Small Region")]))
        XCTAssertEqual(made.mapName.count, 54, made.mapName)
        XCTAssertLessThanOrEqual(made.headerDescription.count,
                                 BuildRecipe.headerDescriptionLimit)

        // And for an id of any length at all.
        made = dated(recipe([region(String(repeating: "very-long-region-", count: 20), "X")]))
        XCTAssertLessThanOrEqual(made.headerDescription.count,
                                 BuildRecipe.headerDescriptionLimit)
    }

    func testTheHeaderDescriptionCarriesTheRegionIdsNotTheirNames() {
        // An id is ASCII whatever the code page; the names live on in `mapName`.
        let made = dated(recipe([region("neighbour-region", "Neighbour Region"),
                                 region("small-region", "Small Region")]))
        XCTAssertEqual(made.headerDescription, "kmap 2026-08, neighbour-region and small-region")
        XCTAssertFalse(made.headerDescription.contains("Neighbour"), made.headerDescription)
    }

    func testTheDeviceCardReadsTheRegionsEverywhere() {
        // A receiver lists the map by its family name and leads its card with the img
        // description: the same words, so the map is recognisable in either place.
        let made = dated(recipe([region("a", "A"), region("b", "B")]))
        XCTAssertEqual(made.deviceTitle, "kmap 2026-08, a and b")
        XCTAssertEqual(made.headerDescription, "kmap 2026-08, a and b")
        XCTAssertEqual(made.familyName, "kmap 2026-08, a and b")
        // The series name repeats the device title, since a receiver displays it only when
        // short; the region names stay in `mapName` for the interface.
        XCTAssertEqual(made.seriesName, made.deviceTitle)
        XCTAssertEqual(made.mapName, "A and B")
    }

    func testTheFamilyNameIsASCIIAndShortWhateverTheRegions() {
        // A name outside the map's code page would reach the receiver as question marks;
        // the ids never leave ASCII. Fitted, so a set of long ids does not run on.
        let french = dated(recipe([region("polynesie-francaise", "Polynésie française (French Polynesia)")]))
        XCTAssertEqual(french.familyName, "kmap 2026-08, polynesie-francaise")
        let many = dated(recipe([region("saint-helena-ascension-and-tristan-da-cunha", "Saint Helena"),
                                 region("ireland-and-northern-ireland", "Ireland"),
                                 region("north-caucasus-fed-district", "North Caucasus")]))
        XCTAssertLessThanOrEqual(many.familyName.count, BuildRecipe.headerDescriptionLimit)
        XCTAssertTrue(many.familyName.hasPrefix("kmap 2026-08, saint-helena"), many.familyName)
        XCTAssertTrue(many.familyName.allSatisfy(\.isASCII))
    }

    func testATitleKeepsTheMonthAndTheCountAndCutsAnIdOnlyAtAHyphen() {
        // The one id past 36 characters in the Geofabrik index, alone and with company.
        let long = "saint-helena-ascension-and-tristan-da-cunha"
        let alone = dated(recipe([region(long, "A")]))
        XCTAssertEqual(alone.deviceTitle, "kmap 2026-08, saint-helena-ascension-and-tristan")
        let three = dated(recipe([region(long, "A"), region("b", "B"), region("c", "C")]))
        XCTAssertEqual(three.deviceTitle, "kmap 2026-08, saint-helena-ascension and 2 more")
        XCTAssertLessThanOrEqual(three.deviceTitle.count, BuildRecipe.headerDescriptionLimit)
    }

    func testATitleThatDoesNotFitNamesOneRegionAndCountsTheRest() {
        // Two ids where they fit, else one and a count, rather than a cut through a word.
        let three = dated(recipe([region("crimean-fed-district", "Crimea"),
                                  region("south-fed-district", "South"),
                                  region("north-caucasus-fed-district", "Caucasus")]))
        XCTAssertEqual(three.deviceTitle, "kmap 2026-08, crimean-fed-district and 2 more")
        // Two long ids do not fit either; two short ones do.
        let twoLong = dated(recipe([region("crimean-fed-district", "Crimea"),
                                    region("south-fed-district", "South")]))
        XCTAssertEqual(twoLong.deviceTitle, "kmap 2026-08, crimean-fed-district and 1 more")
        let two = dated(recipe([region("crimean-fed-district", "Crimea"), region("kuban", "Kuban")]))
        XCTAssertEqual(two.deviceTitle, "kmap 2026-08, crimean-fed-district and kuban")
    }

    func testFittingCutsAtAWordWhereThatLeavesSomethingToRead() {
        XCTAssertEqual(BuildRecipe.fitted("short", to: 20), "short")
        XCTAssertEqual(BuildRecipe.fitted("exactly twenty chars", to: 20), "exactly twenty chars")
        // Past the limit, back to the last word.
        XCTAssertEqual(BuildRecipe.fitted("one two three four five", to: 20), "one two three four")
    }

    func testFittingDoesNotCutAWholeNameBackToItsFirstWord() {
        // Cutting at the only space would leave one character, so the word is cut through.
        let fitted = BuildRecipe.fitted("A ratherlongsinglewordnamethatgoesonandon", to: 20)
        XCTAssertEqual(fitted.count, 20)
        XCTAssertTrue(fitted.hasPrefix("A rather"), fitted)
    }

    // MARK: The file name is bounded too

    func testAFileNameStopsGrowingWithTheRegionsInIt() {
        // Past the limit the slug is cut at a region boundary, so a name stays a name.
        let made = dated(recipe([region("saint-helena-ascension-and-tristan-da-cunha", "A"),
                                 region("ireland-and-northern-ireland", "B")]))
        XCTAssertEqual(made.fileName(),
                       "kmap-saint-helena-ascension-and-tristan-da+1-more-2026-08-21.img")
        XCTAssertLessThanOrEqual(made.fileName().count, 5 + BuildRecipe.fileNamePartLimit + 11 + 4)
        // One id past the limit on its own is cut at a hyphen instead.
        let long = dated(recipe([region(String(repeating: "very-long-region-", count: 5), "C")]))
        XCTAssertTrue(long.fileName().hasPrefix("kmap-very-long-region-very-long-region-"), long.fileName())
        XCTAssertLessThanOrEqual(long.fileName().count, 5 + BuildRecipe.fileNamePartLimit + 11 + 4)
    }

    // MARK: Two builds must not come out as one file

    func testASecondBuildOfTheSameNameGetsANumberRatherThanTheSameFile() {
        // Monaco and Andorra in one style on one day made the same file name, and the
        // second copied to a device silently replaced the first. The name counts ground
        // rather than naming the region - that stays - so a taken name gains "-2".
        let made = dated(recipe([region("region-a", "Region A")]))
        let base = made.fileName()
        XCTAssertTrue(base.hasSuffix("-2026-08-21.img"), base)
        XCTAssertEqual(made.fileName(copy: 2),
                       base.replacingOccurrences(of: ".img", with: "-2.img"))
        XCTAssertEqual(made.fileName(copy: 3),
                       base.replacingOccurrences(of: ".img", with: "-3.img"))
        XCTAssertEqual(made.fileName(copy: 1), base, "the first build carries no number")
    }

    func testEveryPartOfABuildCarriesTheSameNumber() {
        // Part one as "-2" beside an unnumbered part two would stop reading as a set.
        let made = dated(recipe([region("region-a", "Region A")]))
        XCTAssertTrue(made.fileName(ordinal: 1, of: 2, copy: 2).contains("-p1-"))
        XCTAssertTrue(made.fileName(ordinal: 1, of: 2, copy: 2).hasSuffix("-2.img"))
        XCTAssertTrue(made.fileName(ordinal: 2, of: 2, copy: 2).hasSuffix("-2.img"))
    }

    func testTheFreeNumberIsTheFirstOneNothingIsUsing() {
        let made = dated(recipe([region("region-a", "Region A")]))
        XCTAssertEqual(made.freeCopy(of: 1) { _ in false }, 1,
                       "an empty folder needs no number at all")
        let base = made.fileName()
        XCTAssertEqual(made.freeCopy(of: 1) { $0 == base }, 2)
        let second = made.fileName(copy: 2)
        XCTAssertEqual(made.freeCopy(of: 1) { $0 == base || $0 == second }, 3)
    }

    func testOnePartTakenBumpsTheWholeSet() {
        // The parts share a number, so one collision moves them all.
        let made = dated(recipe([region("region-a", "Region A")]))
        let partTwo = made.fileName(ordinal: 2, of: 2)
        let copy = made.freeCopy(of: 2) { $0 == partTwo }
        XCTAssertEqual(copy, 2)
    }

    func testTheCutFallsAtAHyphenSoTheNamesStayWhole() {
        // The header cut at a word; a slug's words are joined by hyphens.
        XCTAssertEqual(BuildRecipe.fitted("parent-region-child-region-small-region",
                                          to: 32, breakingOn: "-"),
                       "parent-region-child-region")
        XCTAssertEqual(BuildRecipe.fitted("short-name", to: 32, breakingOn: "-"),
                       "short-name")
    }
}
