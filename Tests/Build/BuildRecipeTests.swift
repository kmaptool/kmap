import XCTest
@testable import kmap

/// Covers what a build is decided by before any data is read: the family id allocated
/// against `identityKey`, the code page, and the names given to the map and its files.
final class BuildRecipeTests: XCTestCase {

    private func region(_ id: String, _ name: String, parent: String? = nil,
                        box: BBox = .empty) -> Region {
        Region(id: id, name: name, parentID: parent, pbfURL: nil, bbox: box,
               boxes: box.isValid ? [box] : [])
    }

    private let style = MapStyle(id: "borrowed", name: "Borrowed", summary: "",
                                 origin: .builtin, styleDirectory: nil, typURL: nil,
                                 familyID: 6324, productID: 1)

    private func recipe(_ regions: [Region]) -> BuildRecipe {
        BuildRecipe(region: regions[0], extraRegions: Array(regions.dropFirst()),
                    style: style, outputDirectory: URL(fileURLWithPath: "/tmp/out"))
    }

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
        XCTAssertEqual(recipe([a, b, c, d]).mapName, "Region A and 3 more")
    }

    func testTheSlugOfASetNamesTwoAndCountsTheRest() {
        let a = region("continent/region-a", "A"), b = region("continent/region-b", "B")
        let c = region("continent/region-c", "C"), d = region("continent/region-d", "D")
        XCTAssertEqual(recipe([a, b]).slug, "continent-region-a+continent-region-b")
        XCTAssertEqual(recipe([a, b, c]).slug, "continent-region-a+continent-region-b+1")
        XCTAssertEqual(recipe([a, b, c, d]).slug, "continent-region-a+continent-region-b+2")
    }

    // MARK: The family id's key

    func testTheIdentityKeyDoesNotDependOnTheOrderTheRegionsWereChosenIn() {
        // The family id is allocated against this: two maps sharing a key share their tile
        // numbers and hide each other on the device.
        let a = region("continent/region-a", "Region A")
        let b = region("continent/region-b", "Region B")
        XCTAssertEqual(BuildRecipe.identityKey([a, b]), BuildRecipe.identityKey([b, a]))
        XCTAssertEqual(BuildRecipe.identityKey([a, b]), "continent/region-a+continent/region-b")
    }

    func testASetIsNotTheSameIdentityAsOneOfItsMembers() {
        let a = region("continent/region-a", "Region A")
        let b = region("continent/region-b", "Region B")
        XCTAssertNotEqual(BuildRecipe.identityKey([a]), BuildRecipe.identityKey([a, b]))
    }

    func testTheTileIdsStartWhereTheFamilyIdSaysTheyDo() {
        // Tile numbers are family × 10000 + n.
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

    // MARK: The alphabet

    func testACyrillicCountryIsSuggestedItsOwnCodePage() {
        for id in ["russia", "ukraine", "belarus", "serbia", "mongolia"] {
            XCTAssertEqual(BuildRecipe.suggestedCodePage(for: region(id, id)), 1251, id)
        }
        for id in ["germany", "france", "australia", "japan"] {
            XCTAssertEqual(BuildRecipe.suggestedCodePage(for: region(id, id)), 1252, id)
        }
    }

    func testASubRegionIsJudgedByItsParentRatherThanByItsOwnName() throws {
        // A sub-region's own id says nothing about its alphabet; the parent above it does.
        let data = try JSONSerialization.data(withJSONObject: ["features": [
            ["properties": ["id": "russia", "name": "Russia"]],
            ["properties": ["id": "child-region", "name": "Child Region",
                            "parent": "russia"]],
        ]])
        let index = RegionIndex()
        try index.parse(data)
        let child = try XCTUnwrap(index.region("child-region"))
        XCTAssertEqual(BuildRecipe.suggestedCodePage(for: child, in: index), 1251)
        // Without the index there is nothing to walk.
        XCTAssertEqual(BuildRecipe.suggestedCodePage(for: child), 1252)
    }

    func testTheParentWalkStopsRatherThanFollowingACircle() throws {
        let data = try JSONSerialization.data(withJSONObject: ["features": [
            ["properties": ["id": "top", "name": "Top"]],
            ["properties": ["id": "a", "name": "A", "parent": "top"]],
            ["properties": ["id": "b", "name": "B", "parent": "a"]],
        ]])
        let index = RegionIndex()
        try index.parse(data)
        XCTAssertEqual(BuildRecipe.suggestedCodePage(for: index.region("b")!, in: index), 1252)
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

    // MARK: How the map is cut into files

    func testTheSplitModeSurvivesBeingStoredAsAWordAndANumber() {
        for mode in [SplitMode.fitCard, .perRegion, .perCountry, .count(3)] {
            let restored = SplitMode(settingsID: mode.settingsID, count: mode.fileCount)
            XCTAssertEqual(restored, mode, mode.settingsID)
        }
    }

    func testAnUnknownStoredModeFallsBackToTheAutomaticOne() {
        // A settings file from a future version, or a hand-edited one.
        XCTAssertEqual(SplitMode(settingsID: "whatever", count: 0), .fitCard)
        XCTAssertEqual(SplitMode(settingsID: "", count: 0), .fitCard)
        // "custom" with a nonsense count still has to make at least one file.
        XCTAssertEqual(SplitMode(settingsID: "custom", count: 0), .count(1))
        XCTAssertEqual(SplitMode(settingsID: "custom", count: -5), .count(1))
    }

    func testOnlyTheCountedModeCarriesANumber() {
        XCTAssertEqual(SplitMode.fitCard.fileCount, 0)
        XCTAssertEqual(SplitMode.perRegion.fileCount, 0)
        XCTAssertEqual(SplitMode.count(4).fileCount, 4)
        XCTAssertEqual(SplitMode.count(1).label, "1 file")
        XCTAssertEqual(SplitMode.count(4).label, "4 files")
    }

    // MARK: Which way a region is cut

    func testARegionIsCutAcrossItsLongerSideOnTheGroundNotInDegrees() {
        // A degree of longitude is shorter than a degree of latitude everywhere but the
        // equator, and near the pole it is much shorter.
        XCTAssertEqual(SplitAxis.best(for: BBox(minLon: 0, minLat: 0, maxLon: 10, maxLat: 5)),
                       .longitude)
        XCTAssertEqual(SplitAxis.best(for: BBox(minLon: 0, minLat: 0, maxLon: 5, maxLat: 10)),
                       .latitude)
        // Equal in degrees at 70°N: the box is far taller than it is wide on the ground.
        XCTAssertEqual(SplitAxis.best(for: BBox(minLon: 20, minLat: 69, maxLon: 24, maxLat: 73)),
                       .latitude)
        XCTAssertEqual(SplitAxis.best(for: .empty), .longitude)
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

    // MARK: What the finished files are called

    private func dated(_ made: BuildRecipe) -> BuildRecipe {
        var out = made
        var parts = DateComponents()
        parts.year = 2026; parts.month = 8; parts.day = 21
        out.startedOn = Calendar(identifier: .gregorian).date(from: parts)!
        return out
    }

    func testAFinishedFileSaysStyleCountAndDateInThatOrder() {
        // The date sits immediately before the extension, so builds from one card stay
        // distinguishable.
        let made = dated(recipe([region("small-region", "Small Region")]))
        XCTAssertEqual(made.fileName(), "kmap-borrowed-1-regions-2026-08-21.img")
        XCTAssertEqual(made.dateStamp, "2026-08-21")
    }

    func testTheCountIsLeafRegionsWhenTheIndexSuppliedOne() {
        // One chosen entry covers every leaf extract beneath it; the name carries that
        // number, not the count of entries picked.
        var made = dated(recipe([region("continent/large-region", "Large Region")]))
        made.leafRegionCount = 16
        XCTAssertEqual(made.fileName(), "kmap-borrowed-16-regions-2026-08-21.img")
    }

    func testWithoutTheIndexTheChosenRegionsStandIn() {
        let made = dated(recipe([region("a", "A"), region("b", "B"), region("c", "C")]))
        XCTAssertEqual(made.regionsCovered, 3)
        XCTAssertEqual(made.fileName(), "kmap-borrowed-3-regions-2026-08-21.img")
    }

    func testEveryPieceOfASplitMapNamesItsPlaceBeforeTheDate() {
        let made = dated(recipe([region("continent/large-region", "Large Region")]))
        XCTAssertEqual(made.fileName(ordinal: 1, of: 3),
                       "kmap-borrowed-1-regions-p1-2026-08-21.img")
        XCTAssertEqual(made.fileName(ordinal: 3, of: 3),
                       "kmap-borrowed-1-regions-p3-2026-08-21.img")
        // A single file carries no part marker at all.
        XCTAssertEqual(made.fileName(ordinal: 1, of: 1),
                       "kmap-borrowed-1-regions-2026-08-21.img")
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

        // And for a name of any length at all.
        made = dated(recipe([region("x", String(repeating: "Very Long Region ", count: 20))]))
        XCTAssertLessThanOrEqual(made.headerDescription.count,
                                 BuildRecipe.headerDescriptionLimit)
    }

    func testTheHeaderDescriptionCarriesNoRegionNames() {
        // The header slot is bounded; the region names live on in `mapName`.
        let made = dated(recipe([region("neighbour-region", "Neighbour Region"),
                                 region("small-region", "Small Region")]))
        XCTAssertFalse(made.headerDescription.contains("Neighbour"), made.headerDescription)
        XCTAssertFalse(made.headerDescription.contains("Small"), made.headerDescription)
        XCTAssertTrue(made.headerDescription.contains("kmap"), made.headerDescription)
        XCTAssertTrue(made.headerDescription.contains("2026-08-21"), made.headerDescription)
    }

    func testTheDeviceCardReadsTitleThenAttribution() {
        // A receiver's map card shows the img description as its first line and the family
        // name as its second.
        var made = dated(recipe([region("a", "A"), region("b", "B")]))
        made.leafRegionCount = 12
        XCTAssertEqual(made.deviceTitle, "kmap 12 regions 2026-08-21")
        XCTAssertEqual(made.headerDescription, "kmap 12 regions 2026-08-21")
        XCTAssertEqual(made.familyName, "built using kmap")
        // The series name repeats the device title, since a receiver displays it only when
        // short; the region names stay in `mapName` for the interface.
        XCTAssertEqual(made.seriesName, made.deviceTitle)
        XCTAssertEqual(made.mapName, "A and B")
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
        // The name counts regions rather than listing them, so it is bounded for any number.
        var made = dated(recipe([region("region-a", "Region A"),
                                 region("region-b", "Region B")]))
        made.leafRegionCount = 9999
        XCTAssertEqual(made.fileName(), "kmap-borrowed-9999-regions-2026-08-21.img")
        XCTAssertLessThanOrEqual(made.fileName().count, 5 + BuildRecipe.fileNamePartLimit + 11 + 4)
    }

    // MARK: Two builds must not come out as one file

    func testASecondBuildOfTheSameNameGetsANumberRatherThanTheSameFile() {
        // Monaco and Andorra in one style on one day made the same file name, and the
        // second copied to a device silently replaced the first. The name counts ground
        // rather than naming the region — that stays — so a taken name gains "-2".
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

    // MARK: The DEM ladder

    func testTheDEMLadderIsTheMeasuredConstant() {
        // A fixed ladder, validated against hardware.
        let one = LevelsProfile.smooth.demDists(oneArcSecond: true)
        XCTAssertEqual(one, "3312,5568,9360,15760,26496,52992,106048")
        let three = LevelsProfile.smooth.demDists(oneArcSecond: false)
        XCTAssertEqual(three, "9936,12704,16224,20736,26496,52992,106048")
    }

    /// Every ladder is increasing, free of duplicates, no longer than the profile's level
    /// count, and keeps its coarse end whole.
    func testEveryProfileKeepsTheMeasuredCoarseEnd() {
        for profile in LevelsProfile.all {
            for oneArcSecond in [true, false] {
                let where_ = "\(profile.id), \(oneArcSecond ? "1\"" : "3\"")"
                let dists = profile.demDists(oneArcSecond: oneArcSecond)
                    .split(separator: ",").compactMap { Int($0) }
                XCTAssertEqual(dists, dists.sorted(), "\(where_): mkgmap needs them increasing")
                XCTAssertEqual(Set(dists).count, dists.count, "\(where_): a repeated rung is a wasted level")
                XCTAssertLessThanOrEqual(dists.count, profile.levelCount, "\(where_): more rungs than levels")
                XCTAssertTrue(dists.allSatisfy { $0 % 16 == 0 }, "\(where_): mkgmap rounds to 16s")
                XCTAssertEqual(Array(dists.suffix(3)), [26496, 52992, 106048],
                               "\(where_): the measured coarse end must survive whole")
            }
        }
    }
}
