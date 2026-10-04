import XCTest

@testable import kmap

/// Whether mkgmap is handed elevation for the map's own ground and nothing else. A tile's
/// frame reaches past the region, so any cell outside the coverage that is staged is
/// shaded into the finished map.
final class DEMStagingTests: XCTestCase {
    private var pipeline: BuildPipeline!

    @MainActor
    override func setUp() async throws {
        // One degree cell of region, one neighbouring cell, and one far away.
        let region = Region(
            id: "test/here",
            name: "Here",
            parentID: nil,
            pbfURL: nil,
            bbox: BBox(minLon: 34.2, minLat: 44.2, maxLon: 35.6, maxLat: 45.6),
            boxes: [BBox(minLon: 34.2, minLat: 44.2, maxLon: 35.6, maxLat: 45.6)]
        )
        let style = MapStyle(
            id: "plain",
            name: "Plain",
            summary: "",
            origin: .builtin,
            styleDirectory: nil,
            typURL: nil,
            familyID: 6300,
            productID: 1
        )
        var recipe = BuildRecipe(
            region: region,
            style: style,
            outputDirectory: URL(fileURLWithPath: NSTemporaryDirectory())
        )
        recipe.demSources = "copernicus1"
        let settings = SettingsStore()
        let toolchain = Toolchain(settings: settings)
        pipeline = BuildPipeline(
            recipe: recipe,
            settings: settings,
            toolchain: toolchain,
            styles: StyleCatalog(settings: settings, toolchain: toolchain)
        )
    }

    private func plant(_ source: String, _ cells: [String]) throws {
        let dir = Paths.hgtCache.appendingPathComponent(source, isDirectory: true)
        Paths.ensure(dir)
        for cell in cells {
            try FileTools.write(Data(source.utf8), to: dir.appendingPathComponent(cell + ".hgt"))
        }
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: Paths.hgtCache)
    }

    func testOnlyCoverageCellsAreStaged() throws {
        // The chosen source has the region's cells; the fallback also has one outside.
        try plant("COP1", ["N44E034", "N44E035", "N45E034"])
        try plant("VIEW3", ["N44E034", "N45E035", "N50E040"])

        let staged = pipeline.stageDEMCells()
        let dir = try XCTUnwrap(staged.first)
        let names = try FileManager.default.contentsOfDirectory(atPath: dir.path).sorted()

        // The coverage cells only: the cell outside is not staged, whatever cache holds it.
        XCTAssertEqual(names, ["N44E034.hgt", "N44E035.hgt", "N45E034.hgt", "N45E035.hgt"])

        // Read through the cell: it is a link, or a copy where links are refused.
        func source(_ name: String) throws -> String {
            try String(contentsOf: dir.appendingPathComponent(name), encoding: .utf8)
        }
        // The chosen source wins where it has the cell; the fallback fills the holes
        // inside the coverage.
        XCTAssertEqual(try source("N44E034.hgt"), "COP1")
        XCTAssertEqual(try source("N45E035.hgt"), "VIEW3")
    }

    func testTheLikeProviderFillsTheHoleFirst() throws {
        // A 3-arc-second choice falls back to another 3-arc-second source, not a finer one.
        try plant("COP3", ["N44E034"])
        try plant("VIEW1", ["N44E035"])
        try plant("VIEW3", ["N44E035"])

        var recipe = pipeline.recipe
        recipe.demSources = "copernicus3"
        let settings = SettingsStore()
        let toolchain = Toolchain(settings: settings)
        let chose3 = BuildPipeline(
            recipe: recipe,
            settings: settings,
            toolchain: toolchain,
            styles: StyleCatalog(settings: settings, toolchain: toolchain)
        )
        let dir = try XCTUnwrap(chose3.stageDEMCells().first)
        XCTAssertEqual(
            try String(contentsOf: dir.appendingPathComponent("N44E035.hgt"), encoding: .utf8),
            "VIEW3"
        )
    }

    /// A source with nothing left to fill says so in the detailed log only, and asks the
    /// network nothing.
    func testASourceWithNothingLeftSpeaksOnlyInTheDetailedLog() throws {
        try plant("COP1", ["N44E034", "N44E035", "N45E034", "N45E035"])
        var recipe = pipeline.recipe
        recipe.demSources = "copernicus1,fabdem1"
        let settings = SettingsStore()
        let toolchain = Toolchain(settings: settings)
        // Detail kept, as the build screen keeps it for its detailed view.
        let chained = BuildPipeline(
            recipe: recipe,
            settings: settings,
            toolchain: toolchain,
            styles: StyleCatalog(settings: settings, toolchain: toolchain),
            showing: .debug
        )
        let fabdem = try XCTUnwrap(DEMSources.tiled("fabdem1"))
        let bbox = recipe.region.bbox
        try blocking { try await chained.fetchDEMTiles(fabdem, covering: bbox, last: false) }

        let said = chained.log.snapshot()
        XCTAssertEqual(said.filter { $0.text.hasPrefix("nothing left") }.map(\.severity), [.debug])
        XCTAssertEqual(said.filter { $0.severity > .debug }.map(\.text), [])
    }

    func testACreditedSourceTheMapDoesNotNameFillsNothing() throws {
        // FABDEM's licence asks for credit, and only named sources are credited.
        try plant("COP1", ["N44E034"])
        try plant("FAB1", ["N44E034", "N44E035"])
        let dir = try XCTUnwrap(pipeline.stageDEMCells().first)
        XCTAssertTrue(FileTools.exists(dir.appendingPathComponent("N44E034.hgt")))
        XCTAssertFalse(FileTools.exists(dir.appendingPathComponent("N44E035.hgt")))
    }

    /// What decides is the credit a map carries, not the names in its list.
    func testASourceWhoseCreditTheMapCarriesMayFillIt() {
        // FABDEM's credit includes Copernicus's, so Copernicus tiles may fill its gaps.
        XCTAssertEqual(BuildPipeline.uncreditedDirectories(chosen: ["fabdem1"]), ["ged1"])
        // The other way round FABDEM's own line is missing.
        XCTAssertEqual(BuildPipeline.uncreditedDirectories(chosen: ["copernicus1"]), ["fab1", "ged1"])
        XCTAssertEqual(
            BuildPipeline.uncreditedDirectories(chosen: ["view1", "view3"]),
            ["cop1", "cop3", "fab1", "ged1"]
        )
        XCTAssertEqual(BuildPipeline.uncreditedDirectories(chosen: ["gedtm1", "fabdem1"]), [])
    }

    func testTheFetchesFollowTheRecipesOrder() {
        func steps(_ sources: String) -> [String] {
            var recipe = pipeline.recipe
            recipe.demSources = sources
            let settings = SettingsStore()
            let toolchain = Toolchain(settings: settings)
            let built = BuildPipeline(
                recipe: recipe,
                settings: settings,
                toolchain: toolchain,
                styles: StyleCatalog(settings: settings, toolchain: toolchain)
            )
            return built.fetchSteps.map { step in
                switch step {
                case .direct(let source): source.sourceID
                case .viewfinder(let resolutions): "view" + resolutions.map(String.init).joined(separator: "+")
                case .credentialed(let ids): ids.joined(separator: "+")
                }
            }
        }
        // A later source fills only what the earlier ones leave, so it must come later.
        XCTAssertEqual(steps("view1,fabdem1"), ["view1", "fabdem1"])
        XCTAssertEqual(steps("view1,view3,copernicus1"), ["view1+3", "copernicus1"])
        XCTAssertEqual(steps("view1,gedtm1,view3"), ["view1", "gedtm1", "view3"])
        XCTAssertEqual(steps("srtm1,fabdem1,alos1"), ["srtm1+alos1", "fabdem1"])
        XCTAssertEqual(steps("copernicus1,copernicus3"), ["copernicus1", "copernicus3"])
    }

    func testNothingStagedMeansNoDEMOption() throws {
        XCTAssertEqual(
            pipeline.stageDEMCells(),
            [],
            "an empty cache stages nothing rather than an empty directory"
        )
    }
}
