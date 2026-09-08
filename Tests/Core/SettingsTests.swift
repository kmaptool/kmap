import XCTest
@testable import kmap

/// Reading the settings file, including ones written by older builds.
///
/// Swift's synthesized decoder throws on a missing key even where the property has a
/// default, so an added field would make every existing file undecodable.
final class SettingsTests: XCTestCase {

    private func data(_ object: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: object)
    }

    func testACompleteFileIsReadAsItStands() throws {
        var written = Settings.default
        written.outputDirectory = "/somewhere/maps"
        written.javaHeapGB = 12
        var choices = BuildChoices()
        choices.contourInterval = 20
        choices.hiddenFeatures = ["ford", "pipeline"]
        written.profiles = [BuildProfile(id: "p1", name: "Garmin", choices: choices)]
        written.lastProfileID = "p1"

        let decoded = SettingsStore.decode(try JSONEncoder().encode(written))
        XCTAssertEqual(decoded?.outputDirectory, "/somewhere/maps")
        XCTAssertEqual(decoded?.javaHeapGB, 12)
        XCTAssertEqual(decoded?.lastProfileID, "p1")
        XCTAssertEqual(decoded?.profiles.first?.name, "Garmin")
        XCTAssertEqual(decoded?.profiles.first?.choices.contourInterval, 20)
        XCTAssertEqual(decoded?.profiles.first?.choices.hiddenFeatures, ["ford", "pipeline"])
    }

    func testAFileFromAnOlderBuildKeepsWhatItSaysAndTakesTheRestFromTheDefaults() throws {
        // What a file written before half these fields existed looks like.
        let old = try data(["outputDirectory": "/old/maps",
                            "keepWorkFiles": true])
        let decoded = try XCTUnwrap(SettingsStore.decode(old))
        XCTAssertEqual(decoded.outputDirectory, "/old/maps")
        XCTAssertTrue(decoded.keepWorkFiles)
        // Everything it does not mention comes from the defaults, not from zero.
        XCTAssertEqual(decoded.defaultStyleID, Settings.default.defaultStyleID)
        XCTAssertEqual(decoded.downloadConnections, Settings.default.downloadConnections)
        XCTAssertEqual(decoded.maxNodesPerTile, Settings.default.maxNodesPerTile)
        // It names no profiles, so none are decoded.
        XCTAssertTrue(decoded.profiles.isEmpty)
    }

    func testAFileWithAnUnknownFieldIsStillRead() throws {
        // Downgrading after a build that stored something this version knows nothing about.
        let ahead = try data(["outputDirectory": "/maps", "somethingFromTheFuture": 7])
        XCTAssertEqual(SettingsStore.decode(ahead)?.outputDirectory, "/maps")
    }

    func testRubbishIsRefusedRatherThanReadAsEmptySettings() {
        XCTAssertNil(SettingsStore.decode(Data("not json at all".utf8)))
        XCTAssertNil(SettingsStore.decode(Data()))
        // A JSON array is valid JSON and not a settings file.
        XCTAssertNil(SettingsStore.decode(Data("[1, 2, 3]".utf8)))
    }

    func testTheFamilyIDsSurviveAReadTheyAreTheOnlyThingThatCannotBeRegenerated() throws {
        // Two maps sharing a family id hide each other on the receiver, and the table
        // cannot be regenerated from anything else.
        var written = Settings.default
        written.familyIDs = ["continent/region-a": 6300, "continent/region-b": 6301]
        let decoded = SettingsStore.decode(try JSONEncoder().encode(written))
        XCTAssertEqual(decoded?.familyIDs["continent/region-a"], 6300)
        XCTAssertEqual(decoded?.familyIDs["continent/region-b"], 6301)

        // Also through the tolerant path, which is the one an older file takes.
        let partial = try data(["familyIDs": ["continent/region-a": 6300]])
        XCTAssertEqual(SettingsStore.decode(partial)?.familyIDs["continent/region-a"], 6300)
    }

    // MARK: The tile-size migration

    func testTheOldTileDefaultIsLiftedToTheNewOne() throws {
        // 3.5 million was a former default and was never offered on the settings screen,
        // so a stored file carrying it carries no decision.
        var stored = Settings.default
        stored.maxNodesPerTile = 3_500_000
        XCTAssertEqual(SettingsStore.migrated(stored).maxNodesPerTile,
                       Settings.default.maxNodesPerTile)
        XCTAssertEqual(SettingsStore.decode(try JSONEncoder().encode(stored))?.maxNodesPerTile,
                       Settings.default.maxNodesPerTile)
    }

    func testAValueTheUserActuallyChoseIsLeftAlone() throws {
        for chosen in [400_000, 800_000, 1_200_000, 1_600_000, 2_400_000, 5_000_000] {
            var stored = Settings.default
            stored.maxNodesPerTile = chosen
            XCTAssertEqual(SettingsStore.migrated(stored).maxNodesPerTile, chosen)
        }
    }

    func testMigratingTwiceChangesNothingFurther() {
        var stored = Settings.default
        stored.maxNodesPerTile = 3_500_000
        let once = SettingsStore.migrated(stored)
        XCTAssertEqual(SettingsStore.migrated(once).maxNodesPerTile, once.maxNodesPerTile)
    }

    // MARK: Derived values

    func testTheHeapIsExplicitWhenSetAndSensibleWhenNot() {
        var settings = Settings.default
        settings.javaHeapGB = 12
        XCTAssertEqual(settings.resolvedHeapGB, 12)
        settings.javaHeapGB = 0
        // Half of physical memory, never below 2 GB and never above 24.
        XCTAssertGreaterThanOrEqual(settings.resolvedHeapGB, 2)
        XCTAssertLessThanOrEqual(settings.resolvedHeapGB, 24)
    }

    func testAnEmptyWorkFolderMeansTheDefaultRatherThanTheRootOfTheDisk() {
        var settings = Settings.default
        settings.workDirectory = ""
        XCTAssertEqual(settings.workURL, Paths.work)
        settings.workDirectory = "~/scratch"
        XCTAssertFalse(settings.workURL.path.hasPrefix("~"))
        XCTAssertTrue(settings.workURL.path.hasSuffix("/scratch"))
    }

    // MARK: Which elevation source needs a login

    func testOnlyTheSourcesBehindARegistrationAskForOne() {
        XCTAssertNil(ElevationLogins.required(for: "view1,view3"))
        XCTAssertNil(ElevationLogins.required(for: "copernicus"))
        XCTAssertNil(ElevationLogins.required(for: ""))
        XCTAssertEqual(ElevationLogins.required(for: "srtm1,view3"), .srtm)
        XCTAssertEqual(ElevationLogins.required(for: "srtm3"), .srtm)
        XCTAssertEqual(ElevationLogins.required(for: "alos1"), .alos)
        // Both named: the one asked for first is the one the fetch needs first.
        XCTAssertEqual(ElevationLogins.required(for: "srtm1,alos1"), .srtm)
    }

    func testTheLoginFileIsPyhgtmapsAndNotKmapsOwn() {
        // Credentials stay in pyhgtmap's own file; a copy in settings.json would be a
        // second place to leak them from.
        XCTAssertTrue(ElevationLogins.configFile.path.hasSuffix("/.pyhgtmap/config.yaml"),
                      ElevationLogins.configFile.path)
        let encoded = try? JSONEncoder().encode(Settings.default)
        let text = String(data: encoded ?? Data(), encoding: .utf8) ?? ""
        for word in ["password", "srtmUser", "srtm-user", "alosPassword"] {
            XCTAssertFalse(text.lowercased().contains(word.lowercased()),
                           "settings.json has grown a \(word) field")
        }
    }
}
