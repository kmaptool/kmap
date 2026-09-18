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
        let region = Region(id: "test/here", name: "Here", parentID: nil, pbfURL: nil,
                            bbox: BBox(minLon: 34.2, minLat: 44.2, maxLon: 35.6, maxLat: 45.6),
                            boxes: [BBox(minLon: 34.2, minLat: 44.2, maxLon: 35.6, maxLat: 45.6)])
        let style = MapStyle(id: "plain", name: "Plain", summary: "", origin: .builtin,
                             styleDirectory: nil, typURL: nil, familyID: 6300, productID: 1)
        var recipe = BuildRecipe(region: region, style: style,
                                 outputDirectory: URL(fileURLWithPath: NSTemporaryDirectory()))
        recipe.demSources = "copernicus1"
        let settings = SettingsStore()
        let toolchain = Toolchain(settings: settings)
        pipeline = BuildPipeline(recipe: recipe, settings: settings, toolchain: toolchain,
                                 styles: StyleCatalog(settings: settings, toolchain: toolchain))
    }

    private func plant(_ source: String, _ cells: [String]) throws {
        let dir = Paths.hgtCache.appendingPathComponent(source, isDirectory: true)
        Paths.ensure(dir)
        for cell in cells {
            try Data(source.utf8).write(to: dir.appendingPathComponent(cell + ".hgt"))
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

        func source(_ name: String) throws -> String {
            let destination = try FileManager.default.destinationOfSymbolicLink(
                atPath: dir.appendingPathComponent(name).path)
            return URL(fileURLWithPath: destination).deletingLastPathComponent().lastPathComponent
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
        let chose3 = BuildPipeline(recipe: recipe, settings: settings, toolchain: toolchain,
                                   styles: StyleCatalog(settings: settings, toolchain: toolchain))
        let dir = try XCTUnwrap(chose3.stageDEMCells().first)
        let destination = try FileManager.default.destinationOfSymbolicLink(
            atPath: dir.appendingPathComponent("N44E035.hgt").path)
        XCTAssertTrue(destination.contains("VIEW3"), destination)
    }

    func testNothingStagedMeansNoDEMOption() throws {
        XCTAssertEqual(pipeline.stageDEMCells(), [],
                       "an empty cache stages nothing rather than an empty directory")
    }
}
