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
        let region = Region(
            id: "continent/small-region",
            name: "Small Region",
            parentID: nil,
            pbfURL: nil,
            bbox: .empty,
            boxes: []
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
        let recipe = BuildRecipe(region: region, style: style, outputDirectory: directory)
        return BuildPipeline(
            recipe: recipe,
            settings: settings,
            toolchain: toolchain,
            styles: StyleCatalog(settings: settings, toolchain: toolchain)
        )
    }

    /// An extract as the download stage leaves it: the bytes and a stamp with their MD5.
    private func cachedExtract(_ name: String, stamped: Bool = true) throws -> URL {
        let url = directory.appendingPathComponent(name)
        try FileTools.write(Data(repeating: 7, count: 4096), to: url)
        CacheStamp(
            size: 4096,
            lastModified: "then",
            md5: stamped ? try Downloader.md5(of: url) : nil
        ).write(besides: url)
        return url
    }

    func testOnlyAFailureToDecodeTheExtractPointsAtTheExtract() {
        XCTAssertTrue(BuildPipeline.readsLikeADamagedExtract(PBFError.truncated("a blob")))
        XCTAssertTrue(BuildPipeline.readsLikeADamagedExtract(Deflate.Failure.corrupt(Deflate.badData)))
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

    /// A copy put aside comes back with its stamp, or goes where a fresh one came.
    func testACopyPutAsideIsSettled() throws {
        let alone = directory.appendingPathComponent("alone.osm.pbf")
        try FileTools.write(Data("kept".utf8), to: alone.appendingPathExtension("suspect"))
        CacheStamp(size: 4, lastModified: "Mon, 05 Oct 2026 00:00:00 GMT", md5: "abc").write(besides: alone)
        try FileTools.move(CacheStamp.url(for: alone), to: BuildPipeline.keptStamp(besides: alone))
        BuildPipeline.settleSuspect(besides: alone)
        XCTAssertEqual(try Data(contentsOf: alone), Data("kept".utf8))
        // Undated: it vouches for nothing.
        XCTAssertEqual(CacheStamp.read(besides: alone), CacheStamp(size: 4, lastModified: nil, md5: "abc"))
        XCTAssertFalse(FileTools.exists(alone.appendingPathExtension("suspect")))
        XCTAssertFalse(FileTools.exists(BuildPipeline.keptStamp(besides: alone)))

        let fresh = directory.appendingPathComponent("fresh.osm.pbf")
        try FileTools.write(Data("new".utf8), to: fresh)
        try FileTools.write(Data("new stamp".utf8), to: CacheStamp.url(for: fresh))
        try FileTools.write(Data("old".utf8), to: fresh.appendingPathExtension("suspect"))
        try FileTools.write(Data("old stamp".utf8), to: BuildPipeline.keptStamp(besides: fresh))
        BuildPipeline.settleSuspect(besides: fresh)
        XCTAssertEqual(try Data(contentsOf: fresh), Data("new".utf8))
        XCTAssertEqual(try Data(contentsOf: CacheStamp.url(for: fresh)), Data("new stamp".utf8))
        XCTAssertFalse(FileTools.exists(fresh.appendingPathExtension("suspect")))
        XCTAssertFalse(FileTools.exists(BuildPipeline.keptStamp(besides: fresh)))
    }

    /// A damaged copy goes aside with its stamp.
    func testADamagedCopyGoesAsideWithItsStamp() throws {
        let extract = directory.appendingPathComponent("aside.osm.pbf")
        try FileTools.write(Data("bad".utf8), to: extract)
        CacheStamp(size: 3, lastModified: "x", md5: "abc").write(besides: extract)
        let kept = try XCTUnwrap(BuildPipeline.putAside(extract))
        XCTAssertEqual(kept, extract.appendingPathExtension("suspect"))
        XCTAssertFalse(FileTools.exists(extract))
        XCTAssertFalse(FileTools.exists(CacheStamp.url(for: extract)))
        XCTAssertEqual(CacheStamp.read(at: BuildPipeline.keptStamp(besides: extract))?.md5, "abc")
    }

    /// Any stamp beside a copy put back loses its date; one unreadable leaves a marker.
    func testAnyStampBesideACopyPutBackStopsVouching() throws {
        let stray = directory.appendingPathComponent("stray.osm.pbf")
        try FileTools.write(Data("kept".utf8), to: stray.appendingPathExtension("suspect"))
        CacheStamp(size: 4, lastModified: "Mon, 05 Oct 2026 00:00:00 GMT", md5: "abc").write(besides: stray)
        BuildPipeline.settleSuspect(besides: stray)
        XCTAssertEqual(CacheStamp.read(besides: stray), CacheStamp(size: 4, lastModified: nil, md5: "abc"))

        let unreadable = directory.appendingPathComponent("unreadable.osm.pbf")
        try FileTools.write(Data("kept".utf8), to: unreadable.appendingPathExtension("suspect"))
        try FileTools.write(Data("not json".utf8), to: BuildPipeline.keptStamp(besides: unreadable))
        BuildPipeline.settleSuspect(besides: unreadable)
        XCTAssertEqual(CacheStamp.read(besides: unreadable), CacheStamp(size: -1, lastModified: nil, md5: nil))
        XCTAssertFalse(FileTools.exists(BuildPipeline.keptStamp(besides: unreadable)))
    }
}
