import XCTest
@testable import kmap

/// Telling a cached extract damaged on disk from a build that failed for its own reasons.
final class ExtractRepairTests: XCTestCase {

    private var directory = URL(fileURLWithPath: "/tmp")

    override func setUpWithError() throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("kmap-repair-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func pipeline() -> BuildPipeline {
        let settings = SettingsStore()
        let toolchain = Toolchain(settings: settings)
        let region = Region(id: "continent/small-region", name: "Small Region",
                            parentID: nil, pbfURL: nil, bbox: .empty, boxes: [])
        let style = MapStyle(id: "plain", name: "Plain", summary: "", origin: .builtin,
                             styleDirectory: nil, typURL: nil, familyID: 6300, productID: 1)
        let recipe = BuildRecipe(region: region, style: style, outputDirectory: directory)
        return BuildPipeline(recipe: recipe, settings: settings, toolchain: toolchain,
                             styles: StyleCatalog(settings: settings, toolchain: toolchain))
    }

    /// An extract as the download stage leaves it: the bytes and a stamp with their MD5.
    private func cachedExtract(_ name: String, stamped: Bool = true) throws -> URL {
        let url = directory.appendingPathComponent(name)
        try Data(repeating: 7, count: 4096).write(to: url)
        CacheStamp(size: 4096, lastModified: "then",
                   md5: stamped ? try Downloader.md5(of: url) : nil).write(besides: url)
        return url
    }

    func testOnlyAFailureToDecodeTheExtractPointsAtTheExtract() {
        XCTAssertTrue(BuildPipeline.readsLikeADamagedExtract(PBFError.truncated("a blob")))
        XCTAssertTrue(BuildPipeline.readsLikeADamagedExtract(Zlib.Failure.corrupt(-3)))
        XCTAssertFalse(BuildPipeline.readsLikeADamagedExtract(BuildError.notDownloadable("x")))
        XCTAssertFalse(BuildPipeline.readsLikeADamagedExtract(DownloadError.badStatus(503)))
        XCTAssertFalse(BuildPipeline.readsLikeADamagedExtract(CancellationError()))
    }

    func testAnExtractDamagedWithoutChangingSizeIsFound() throws {
        let sound = try cachedExtract("sound.osm.pbf")
        let damaged = try cachedExtract("damaged.osm.pbf")
        let handle = try FileHandle(forWritingTo: damaged)
        try handle.seek(toOffset: 2048)
        try handle.write(contentsOf: Data(repeating: 0, count: 64))
        try handle.close()
        XCTAssertEqual(FileTools.size(of: damaged), 4096, "the size gives nothing away")

        XCTAssertEqual(pipeline().damagedExtracts(among: [sound, damaged]), [damaged])
    }

    func testSoundExtractsLeaveTheFailureToWhoeverCausedIt() throws {
        let extracts = [try cachedExtract("a.osm.pbf"), try cachedExtract("b.osm.pbf")]
        XCTAssertTrue(pipeline().damagedExtracts(among: extracts).isEmpty)
    }

    func testAnExtractWithNoRecordedChecksumIsFetchedAgain() throws {
        // Nothing to compare against, so fetching it again is the only check there is.
        let unknown = try cachedExtract("no-md5.osm.pbf", stamped: false)
        XCTAssertEqual(pipeline().damagedExtracts(among: [unknown]), [unknown])
    }
}
