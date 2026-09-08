import XCTest
@testable import kmap

/// Where kmap keeps things.
///
/// Everything lives under ~/.kmap except finished maps. Checked by shape rather than by
/// value: the tests must not create or move anything in a real home directory.
final class PathsTests: XCTestCase {

    func testEverythingKmapOwnsSitsUnderOneRoot() {
        // The root's name does not matter; a test run gets one of its own. See
        // `Paths.isATestRun`.
        let root = Paths.root.path
        XCTAssertFalse(root.isEmpty)
        for url in [Paths.settingsFile, Paths.cache, Paths.indexCache, Paths.pbfCache,
                    Paths.hgtCache, Paths.tools, Paths.venv,
                    Paths.seaData, Paths.boundsData, Paths.styles, Paths.work, Paths.logs] {
            XCTAssertTrue(url.path.hasPrefix(root + "/"), url.path)
        }
    }

    /// The root a real run uses, which is not this process's test root.
    func testTheRealRootIsTheDotDirectoryInTheHome() {
        XCTAssertEqual(Paths.home.appendingPathComponent(".kmap").path,
                       Paths.home.path + "/.kmap")
        #if !os(Windows)
        XCTAssertEqual(Paths.defaultRoot().path, Paths.home.path + "/.kmap")
        #endif
    }

    // MARK: Where the root is, per platform

    func testWindowsPutsItInLocalAppDataRatherThanADotDirectory() {
        // Local rather than Roaming: the caches must not be copied around a domain
        // network at every login.
        let root = Paths.defaultRoot(.windows,
                                     environment: ["LOCALAPPDATA": #"C:\Users\k\AppData\Local"#])
        // Compared by its tail: from a Mac a drive letter is a relative name, so the URL
        // picks up the working directory in front of it.
        XCTAssertTrue(root.nativePath.hasSuffix(#"C:\Users\k\AppData\Local"# + "/kmap")
                      || root.nativePath.hasSuffix(#"C:\Users\k\AppData\Local\kmap"#),
                      root.nativePath)
    }

    func testWindowsWithoutTheVariableFallsBackToWhereItAlwaysIs() {
        // With a stripped environment the fixed layout is assumed, rather than writing a
        // folder named "" at the drive root.
        let root = Paths.defaultRoot(.windows, environment: [:])
        XCTAssertTrue(root.path.hasSuffix("/AppData/Local/kmap"), root.path)
        XCTAssertTrue(root.path.hasPrefix(Paths.home.path), root.path)
    }

    func testEveryUnixKeepsTheDotDirectoryItAlwaysHad() {
        // Including WSL, where it is the Linux home that matters and not the Windows one.
        for platform in [Platform.macOS, .linux, .wsl] {
            XCTAssertEqual(Paths.defaultRoot(platform,
                                             environment: ["LOCALAPPDATA": #"C:\x"#]).path,
                           Paths.home.path + "/.kmap", "\(platform)")
        }
    }

    func testAnEmptyVariableIsTreatedAsAbsentRatherThanAsARootDirectory() {
        let root = Paths.defaultRoot(.windows, environment: ["LOCALAPPDATA": ""])
        XCTAssertTrue(root.path.hasSuffix("/AppData/Local/kmap"), root.path)
    }

    func testTheFinishedMapsGoOutsideItWhereAPersonCanFindThem() {
        XCTAssertFalse(Paths.defaultOutput.path.hasPrefix(Paths.root.path))
        // In the home directory, not a temporary one and not hidden.
        XCTAssertEqual(Paths.defaultOutput(.macOS).path, Paths.home.path + "/kmap")
        XCTAssertEqual(Paths.defaultOutput(.linux).path, Paths.home.path + "/kmap")
    }

    func testOnWindowsTheyGoWhereWindowsPutsWhatAPersonMade() {
        let made = Paths.defaultOutput(.windows, environment: ["USERPROFILE": #"C:\Users\k"#])
        XCTAssertTrue(made.path.hasSuffix("/Documents/kmap"), made.path)
        XCTAssertTrue(made.path.contains("Users"), made.path)
    }

    func testAnEmptyProfileVariableFallsBackToTheHomeDirectory() {
        let made = Paths.defaultOutput(.windows, environment: ["USERPROFILE": ""])
        XCTAssertTrue(made.path.hasPrefix(Paths.home.path), made.path)
        XCTAssertTrue(made.path.hasSuffix("/Documents/kmap"), made.path)
    }

    func testTheCachesAreToldApartSoOneDoesNotClearTheOther() {
        // The screen offers to clear the two caches separately.
        XCTAssertNotEqual(Paths.pbfCache, Paths.hgtCache)
        XCTAssertEqual(Paths.pbfCache.lastPathComponent, "pbf")
        XCTAssertEqual(Paths.hgtCache.lastPathComponent, "hgt")
        XCTAssertEqual(Paths.indexCache.lastPathComponent, "geofabrik-index.json")
    }

    func testATildeIsExpandedSoAPersonCanTypePathsNaturally() {
        let home = Paths.home.path
        XCTAssertEqual(Paths.expand("~/Maps").path, home + "/Maps")
        XCTAssertEqual(Paths.expand("  ~/Maps  ").path, home + "/Maps")
        XCTAssertEqual(Paths.expand("~").path, home)
        // An absolute path is left where it is.
        XCTAssertEqual(Paths.expand("/Volumes/Card/Garmin").path, "/Volumes/Card/Garmin")
    }

    func testDisplayShortensTheHomeDirectoryAndLeavesTheRestAlone() {
        XCTAssertEqual(Paths.display(Paths.home.appendingPathComponent("Garmin/kmap")),
                       "~/Garmin/kmap")
        XCTAssertEqual(Paths.display(URL(fileURLWithPath: "/Volumes/Card")), "/Volumes/Card")
    }

    func testExpandingAndDisplayingAreTheSameJourneyBackAndForth() {
        for path in ["~/Garmin/kmap", "~/Maps", "/Volumes/Card/Garmin"] {
            XCTAssertEqual(Paths.display(Paths.expand(path)), path)
        }
    }
}
