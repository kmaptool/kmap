import XCTest
@testable import kmap

/// What a profile carries, what it does not, and that applying one changes the recipe only.
final class ProfilesTests: XCTestCase {

    private var store: SettingsStore!

    override func setUp() {
        super.setUp()
        // Drives the real store; the settings file is restored on teardown.
        store = SettingsStore()
        let profiles = store.settings.profiles
        let last = store.settings.lastProfileID
        addTeardownBlock { [store] in
            store?.update { $0.profiles = profiles; $0.lastProfileID = last }
        }
        // Known state: exactly one profile.
        store.update {
            $0.profiles = [BuildProfile(id: "base", name: "Base")]
            $0.lastProfileID = "base"
        }
    }

    private var region: Region {
        Region(id: "continent/inland-region", name: "Inland Region", parentID: "continent",
               pbfURL: URL(string: "https://example.invalid/inland-region.osm.pbf"),
               bbox: BBox(minLon: 9, minLat: 46, maxLon: 17, maxLat: 49), boxes: [])
    }

    private var style: MapStyle {
        MapStyle(id: "plain", name: "Plain", summary: "", origin: .builtin,
                 styleDirectory: StyleCatalog.baseStyleDirectory,
                 typURL: nil, familyID: 6324, productID: 1)
    }

    private func recipe() -> BuildRecipe {
        BuildRecipe(region: region, style: style,
                    outputDirectory: URL(fileURLWithPath: "/maps"))
    }

    // MARK: A profile meeting a recipe

    func testEveryChoiceSurvivesTheTripIntoARecipeAndBackOut() {
        // A field added to one side of the round trip and not the other fails here.
        var choices = BuildChoices()
        choices.contours = false
        choices.contourInterval = 25
        choices.demLayer = false
        choices.demSources = "copernicus1"
        choices.levelsID = LevelsProfile.standard.id
        choices.labelLanguageID = LabelLanguage.russian.id
        choices.codePage = 1251
        choices.routable = false
        choices.healRoadEnds = true
        choices.searchIndex = false
        choices.splitNameIndex = false
        choices.houseNumbers = false
        choices.generateSea = false
        choices.descriptions = BuildRecipe.DescriptionCarrier.inName.rawValue
        choices.customPOIs = true
        choices.hiddenFeatures = ["benches", "ford"]
        choices.splitMode = "custom"
        choices.parts = 3

        var map = recipe()
        map.apply(choices, style: style, regionCodePage: 1252)
        XCTAssertEqual(map.choices, choices)
    }

    func testWhatBelongsToTheMapIsLeftWhereItIs() {
        // A profile must not carry a family id between maps: two maps sharing one hide each
        // other on the device.
        var map = recipe()
        map.familyID = 6377
        map.leafRegionCount = 9
        map.apply(BuildChoices(), style: style, regionCodePage: 1252)

        XCTAssertEqual(map.familyID, 6377)
        XCTAssertEqual(map.leafRegionCount, 9)
        XCTAssertEqual(map.region.id, "continent/inland-region")
        XCTAssertEqual(map.outputDirectory.path, "/maps")
    }

    func testAProfileThatLeavesTheCodePageOpenTakesTheRegionsOwn() {
        var choices = BuildChoices()
        choices.codePage = 0

        var cyrillic = recipe()
        cyrillic.apply(choices, style: style, regionCodePage: 1251)
        XCTAssertEqual(cyrillic.codePage, 1251)

        var western = recipe()
        western.apply(choices, style: style, regionCodePage: 1252)
        XCTAssertEqual(western.codePage, 1252)

        // Neither counts as an edit: the profile asked for the region's own code page.
        XCTAssertTrue(cyrillic.matches(choices, regionCodePage: 1251, askedStyleID: "plain"))
        XCTAssertTrue(western.matches(choices, regionCodePage: 1252, askedStyleID: "plain"))
    }

    func testHiddenFeaturesInAnyOrderAreTheSameChoice() {
        // The recipe holds a set, so the same features in any order are the same profile.
        var choices = BuildChoices()
        choices.hiddenFeatures = ["power-tower", "barriers-fence", "amenity-public_building",
                                  "barriers-fence"]

        var map = recipe()
        map.apply(choices, style: style, regionCodePage: 1252)
        XCTAssertTrue(map.matches(choices, regionCodePage: 1252, askedStyleID: "plain"))
    }

    func testAStyleStillBeingLookedForOnTheDrivesIsNotACange() {
        // A profile may name a style still being scanned for; the stand-in must not read as
        // an edit until it is found.
        var choices = BuildChoices()
        choices.styleID = "typ:borrowed"

        var map = recipe()
        map.apply(choices, style: nil, regionCodePage: 1252)
        XCTAssertEqual(map.style.id, "plain", "the stand-in stays until the scan lands")
        XCTAssertTrue(map.matches(choices, regionCodePage: 1252,
                                  askedStyleID: "typ:borrowed"))
    }

    func testAnEditedFormReadsAsEditedAndTheProfileIsUntouched() {
        let profile = BuildProfile(name: "Garmin 67", choices: BuildChoices())
        var map = recipe()
        map.apply(profile.choices, style: style, regionCodePage: 1252)
        XCTAssertTrue(map.matches(profile.choices, regionCodePage: 1252, askedStyleID: "plain"))

        map.contourInterval = 50
        XCTAssertFalse(map.matches(profile.choices, regionCodePage: 1252,
                                   askedStyleID: "plain"))
        XCTAssertEqual(profile.choices.contourInterval, 10,
                       "a change on the build form must not reach the profile")
    }

    // MARK: The order they are offered in

    func testLatinNamesComeFirstThenCyrillicAndEachAlphabetIsInItsOwnOrder() {
        let names = ["Ястреб", "garmin 67", "Авто", "Zumo", "Alpha", "яхта", "Ёлка", "Едем"]
        let sorted = names.map { BuildProfile(name: $0) }
            .sorted(by: BuildProfile.precedes)
            .map(\.name)
        XCTAssertEqual(sorted,
                       ["Alpha", "garmin 67", "Zumo", "Авто", "Едем", "Ёлка", "Ястреб", "яхта"])
    }

    func testTheOrderDoesNotDependOnWhichLanguageTheInterfaceIsSpeaking() {
        let was = L10n.current
        defer { L10n.use(was) }
        let names = ["Zumo", "Авто", "Alpha", "Ёлка"].map { BuildProfile(name: $0) }

        L10n.use(.en)
        let english = names.sorted(by: BuildProfile.precedes).map(\.name)
        L10n.use(.ru)
        let russian = names.sorted(by: BuildProfile.precedes).map(\.name)
        XCTAssertEqual(english, russian)
        XCTAssertEqual(english, ["Alpha", "Zumo", "Авто", "Ёлка"])
    }

    // MARK: Keeping them

    func testTheFirstRunMakesAProfileToOpenOn() {
        // The build screen's choices live in a profile from first launch onwards.
        store.update { $0.profiles = []; $0.lastProfileID = "" }
        store.ensureProfile()
        XCTAssertEqual(store.profiles.count, 1)
        XCTAssertEqual(store.currentProfile.id, store.profiles[0].id)
        XCTAssertFalse(store.currentProfile.name.isEmpty)

        // Only once: a second call is not a second profile.
        store.ensureProfile()
        XCTAssertEqual(store.profiles.count, 1)
    }

    func testANameAlreadyTakenIsNumberedRatherThanDuplicated() {
        let first = store.addProfile(named: "Garmin")
        let second = store.addProfile(named: "Garmin")
        let third = store.addProfile(named: "garmin")
        XCTAssertEqual(first.name, "Garmin")
        XCTAssertEqual(second.name, "Garmin 2")
        // Numbered from the same base, case-insensitively; the case typed in is kept.
        XCTAssertEqual(third.name, "garmin 3")
    }

    func testRenamingKeepsTheProfilesOwnNameAvailableToIt() {
        let profile = store.addProfile(named: "Etrex")
        store.renameProfile(profile.id, to: "Etrex")
        XCTAssertEqual(store.profile(profile.id)?.name, "Etrex",
                       "renaming a profile to what it is already called is not a clash")
    }

    func testWhichProfileTheBuildScreenOpensOnIsRemembered() {
        let profile = store.addProfile(named: "Roaming")
        store.useProfile(profile.id)
        XCTAssertEqual(store.currentProfile.id, profile.id)
        // On disk, not only in this instance.
        XCTAssertEqual(SettingsStore().currentProfile.id, profile.id)
    }

    func testSavingAProfileWritesOverTheOneItCameFrom() {
        var profile = store.addProfile(named: "Detailed")
        profile.choices.contourInterval = 20
        store.saveProfile(profile)
        XCTAssertEqual(store.profile(profile.id)?.choices.contourInterval, 20)
        XCTAssertEqual(store.settings.profiles.filter { $0.id == profile.id }.count, 1)
    }

    func testTheLastProfileStaysBecauseTheBuildScreenOpensOnOne() {
        store.update { $0.profiles = [BuildProfile(id: "only", name: "Only")]
                       $0.lastProfileID = "only" }
        XCTAssertFalse(store.deleteProfile("only"))
        XCTAssertEqual(store.profiles.count, 1)
    }

    func testDeletingTheOneInUseMovesTheChoiceToAnotherRatherThanToNothing() {
        let kept = store.addProfile(named: "Kept")
        let going = store.addProfile(named: "Going")
        store.useProfile(going.id)

        XCTAssertTrue(store.deleteProfile(going.id))
        XCTAssertNil(store.profile(going.id))
        XCTAssertNotEqual(store.currentProfile.id, going.id)
        XCTAssertFalse(store.currentProfile.id.isEmpty)
        XCTAssertNotNil(store.profile(kept.id))
    }

    /// The hidden set is sorted and deduplicated on assignment and on decoding, so plain
    /// equality compares two of them.
    func testTheHiddenSetIsCanonicalOnEveryWrite() throws {
        var choices = BuildChoices()
        choices.hiddenFeatures = ["power-tower", "barriers-fence", "power-tower"]
        XCTAssertEqual(choices.hiddenFeatures, ["barriers-fence", "power-tower"])

        let json = """
        {"hiddenFeatures": ["z-last", "a-first", "a-first"]}
        """
        let decoded = try JSONDecoder().decode(BuildChoices.self, from: Data(json.utf8))
        XCTAssertEqual(decoded.hiddenFeatures, ["a-first", "z-last"])
    }
}
