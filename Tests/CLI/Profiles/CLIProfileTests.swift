import XCTest

@testable import kmap

/// What a command-line build starts from: `CLI.bare`, or the choices of the profile named
/// by `--profile`. A flag overrides either, in both directions.
final class CLIProfileTests: XCTestCase {
    private var store: SettingsStore!

    override func setUp() {
        super.setUp()
        store = SettingsStore()
        let profiles = store.settings.profiles
        let last = store.settings.lastProfileID
        addTeardownBlock { [store] in
            store?.update {
                $0.profiles = profiles; $0.lastProfileID = last
            }
        }
        var coarse = BuildChoices()
        coarse.contourInterval = 50
        coarse.styleID = "typ:borrowed"
        coarse.demLayer = false
        store.update {
            $0.profiles = [
                BuildProfile(id: "a", name: "Handheld", choices: coarse),
                BuildProfile(id: "b", name: "Оregon")
            ]
            $0.lastProfileID = "b"
        }
    }

    func testNoFlagMeansNoProfileAtAll() {
        // "b" is the profile the interface opens on; a build without `--profile` ignores it.
        XCTAssertEqual(CLI.chosenChoices(nil, in: store), CLI.bare)
        XCTAssertEqual(store.currentProfile.id, "b")
    }

    /// Every optional part of a map is off in `CLI.bare` until a flag asks for it.
    func testABareCommandLineAddsNothing() {
        XCTAssertEqual(CLI.bare.styleID, "plain")
        XCTAssertFalse(CLI.bare.contours)
        XCTAssertFalse(CLI.bare.demLayer)
        // Summits follow the DEM: idle without it, on with it as the usage promises.
        XCTAssertTrue(CLI.bare.fixSummits)
        XCTAssertFalse(CLI.bare.routable)
        XCTAssertFalse(CLI.bare.searchIndex)
        XCTAssertFalse(CLI.bare.splitNameIndex)
        XCTAssertFalse(CLI.bare.houseNumbers)
        XCTAssertFalse(CLI.bare.generateSea)
        XCTAssertFalse(CLI.bare.customPOIs)
        XCTAssertFalse(CLI.bare.healRoadEnds)
        XCTAssertEqual(CLI.bare.descriptions, BuildRecipe.DescriptionCarrier.off.rawValue)
        XCTAssertTrue(CLI.bare.hiddenFeatures.isEmpty)
    }

    /// The default style stored for the interface does not reach a command-line build.
    func testTheDefaultStyleFromSettingsDoesNotReachACommandLine() {
        let stored = store.settings.defaultStyleID
        addTeardownBlock { [store] in store?.update { $0.defaultStyleID = stored } }

        store.update { $0.defaultStyleID = "typ:whatever-was-made-default" }
        XCTAssertEqual(CLI.chosenChoices(nil, in: store)?.styleID, "plain")
        // A named profile carries its own style.
        XCTAssertEqual(CLI.chosenChoices("Handheld", in: store)?.styleID, "typ:borrowed")
    }

    func testANameOnTheCommandLineStartsFromThatProfile() {
        XCTAssertEqual(CLI.chosenChoices("Handheld", in: store)?.contourInterval, 50)
        XCTAssertEqual(CLI.chosenChoices("Handheld", in: store)?.styleID, "typ:borrowed")
        XCTAssertEqual(CLI.chosenChoices("Handheld", in: store)?.demLayer, false)
    }

    func testTheNameIsNotFussyAboutCase() {
        XCTAssertEqual(CLI.chosenChoices("handheld", in: store)?.contourInterval, 50)
        XCTAssertEqual(CLI.chosenChoices("HANDHELD", in: store)?.contourInterval, 50)
    }

    func testANameNothingAnswersToIsRefusedRatherThanFallenBackFrom() {
        XCTAssertNil(CLI.chosenChoices("Montana", in: store))
        // A prefix of a profile name is not a match either.
        XCTAssertNil(CLI.chosenChoices("GPS", in: store))
        XCTAssertNil(CLI.chosenChoices("", in: store))
    }

    // MARK: What the flags can argue with

    /// Every choice a profile carries has a flag that moves it in both directions. Hidden
    /// features are the exception: `--hide=` replaces the list wholesale.
    func testEveryChoiceAProfileCarriesHasAFlagThatMovesIt() {
        // Read off the type rather than listed by hand: a choice added to `BuildChoices`
        // with no flag to move it fails here.
        let covered: Set<String> = [
            "styleID",  // --style
            "contours",  // --contours / --no-contours
            "contourInterval",  // --interval
            "demLayer",  // --dem / --no-dem
            "fixSummits",  // --summits / --no-summits
            "demSources",  // --sources
            "levelsID",  // --levels
            "labelLanguageID",  // --labels
            "codePage",  // --code-page, =auto to hand it back to the region
            "routable",  // --route / --no-route
            "healRoadEnds",  // --repair-ends / --no-repair-ends
            "searchIndex",  // --index / --no-index
            "splitNameIndex",  // --word-index / --no-word-index
            "houseNumbers",  // --house-numbers / --no-house-numbers
            "generateSea",  // --sea / --no-sea
            "zoomPlanID",  // --zoom-plan=<name>
            "descriptions",  // --descriptions[=carrier], =off to turn it back off
            "customPOIs",  // --custom-pois / --no-custom-pois
            "hiddenFeatures",  // --hide=a,b,c, or --hide= for none
            "splitMode",  // --split
            "parts",  // --parts
            "format",  // --format
            "theme",  // --theme
            "shapeOverlap",  // --overlap
            "landOverlap"  // --land-overlap
        ]
        let carried = Set(Mirror(reflecting: BuildChoices()).children.compactMap(\.label))
        XCTAssertEqual(
            carried.subtracting(covered),
            [],
            "a profile choice with no flag to override it"
        )
        XCTAssertEqual(
            covered.subtracting(carried),
            [],
            "a flag for a choice that no longer exists"
        )
    }

    /// A command-line build reads profiles and writes none of them: neither their choices
    /// nor which one the interface opens on.
    func testABuildLeavesEveryProfileExactlyWhereItWas() {
        let before = store.settings.profiles
        _ = CLI.chosenChoices("Handheld", in: store)
        _ = CLI.chosenChoices(nil, in: store)
        _ = CLI.chosenChoices("nothing called this", in: store)

        XCTAssertEqual(store.settings.profiles, before)
        XCTAssertEqual(store.currentProfile.id, "b")
        // On disk as well as in this instance.
        let reread = SettingsStore()
        XCTAssertEqual(reread.settings.profiles, before)
        XCTAssertEqual(reread.currentProfile.id, "b")
    }
}

extension CLIProfileTests {
    /// A numeric flag outside the range it allows, or not a number at all, is refused with
    /// exit code 2 rather than clamped.
    func testAnImpossibleNumberIsRefused() async {
        for bad in [
            "--heap=0", "--heap=99999", "--connections=0", "--connections=17",
            "--repair-radius=-1", "--repair-radius=500", "--memory=0",
            "--heap=lots", "--connections=some",
            // mkgmap would stop on these only at the compile, after the download.
            "--code-page=125", "--code-page=12345", "--code-page=-1"
        ] {
            let code = await CLI.run(["build", "region-a", bad])
            XCTAssertEqual(code, 2, "\(bad) should be refused")
        }
    }

    func testThePagesMkgmapTakesAreTaken() {
        for page in ["1253", "866", "65001", "auto", "0"] {
            var choices = BuildChoices()
            XCTAssertEqual(CLI.apply(CLI.Flags(["--code-page=\(page)"]), to: &choices, store: store), [], page)
        }
    }

    func testAFlagBuildDoesNotKnowIsRefusedNotIgnored() async {
        // A typo used to be silent, and the hour-long build got the profile's value.
        for bad in ["--no-contorus", "--sources=copernikus1", "--sources=", "--dem=yes", "--dem=no", "--no-sea=1"] {
            let code = await CLI.run(["build", "region-a", bad])
            XCTAssertEqual(code, 2, "\(bad) should be refused")
        }
        XCTAssertEqual(CLI.unknownSources(in: "copernicus1, view3,srtm1,alos1,copernicus90"), [])
        XCTAssertEqual(CLI.unknownSources(in: "copernicus1,mars"), ["mars"])
        // pyhgtmap's own by their exact names: a word that only starts like one is not one.
        // alos3 too: pyhgtmap refuses it, and with it the whole fetch of the login sources.
        XCTAssertEqual(CLI.unknownSources(in: "srtm3,srtm7,alos3,alos99"), ["srtm7", "alos3", "alos99"])
    }

    /// An overlap off the 128 step would be rounded silently: it is refused instead.
    func testAnOverlapOffItsStepIsRefused() {
        var choices = BuildChoices()
        let refused = CLI.apply(CLI.Flags(["--overlap=200", "--land-overlap=60"]), to: &choices, store: store)
        XCTAssertEqual(
            refused,
            ["--overlap=200 is not a multiple of 128", "--land-overlap=60 is not a multiple of 128"]
        )
        XCTAssertTrue(CLI.apply(CLI.Flags(["--overlap=256", "--land-overlap=128"]), to: &choices, store: store).isEmpty)
        XCTAssertEqual(choices.shapeOverlap, 256)
        XCTAssertEqual(choices.landOverlap, 128)
    }

    /// A switch is on by being written, so `--dem=no` used to turn the layer on. A value
    /// on one is refused, for a profile as for a build.
    func testASwitchGivenAValueIsRefusedRatherThanTurnedOn() {
        var choices = BuildChoices()
        choices.demLayer = false
        let refused = CLI.apply(CLI.Flags(["--dem=no"]), to: &choices, store: store)
        XCTAssertEqual(refused, ["--dem takes no value: write --dem or --no-dem"])
        XCTAssertTrue(CLI.apply(CLI.Flags(["--dem", "--no-sea"]), to: &choices, store: store).isEmpty)
    }

    /// What `--memory` says is what the lanes are worked out from.
    func testMemoryToldIsMemoryUsed() {
        let was = Machine.memoryGB
        addTeardownBlock { Machine.told(was) }
        Machine.told(6)
        XCTAssertEqual(Machine.memoryGB, 6)
        XCTAssertEqual(Machine.lanes(10, holdingEach: 0.7), 4)
    }

    /// An override made for one run stays in the process; a family id allocated during it
    /// is durable. A save writes the second and not the first.
    func testAnOverrideForTheRunNeverReachesTheFile() {
        let stored = store.settings.outputDirectory
        store.overrideForRun { $0.outputDirectory = "/tmp/kmap-one-off" }
        XCTAssertEqual(store.settings.outputDirectory, "/tmp/kmap-one-off", "this run sees it")

        let key = "override-test-\(UUID().uuidString.prefix(6))"
        let allocated = store.familyID(for: key)
        addTeardownBlock { [store] in store?.update { $0.familyIDs[key] = nil } }

        let reread = SettingsStore()
        XCTAssertEqual(reread.settings.outputDirectory, stored, "the file kept its own")
        XCTAssertEqual(reread.settings.familyIDs[key], allocated, "the durable change landed")
        XCTAssertEqual(
            store.settings.outputDirectory,
            "/tmp/kmap-one-off",
            "and the override still stands in this run after the save"
        )
    }
}
