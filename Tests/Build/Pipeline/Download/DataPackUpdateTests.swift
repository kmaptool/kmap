import XCTest
@testable import kmap

/// When a build asks whether the two data packs have moved on: only what it reads, only
/// what is installed, only as often as Settings says.
final class DataPackUpdateTests: XCTestCase {

    private var folder: URL!

    override func setUpWithError() throws {
        folder = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("packs-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: self.folder) }
    }

    /// A pack of a given size on disk, with the file date a real install would leave.
    private func pack(bytes: Int = 2_000_000, downloaded: Date = Date()) throws -> DataPack {
        let file = folder.appendingPathComponent("pack.zip")
        try Data(repeating: 0, count: bytes).write(to: file)
        try FileManager.default.setAttributes([.modificationDate: downloaded],
                                              ofItemAtPath: file.path)
        return DataPack(id: "test", url: URL(string: "https://example.invalid/pack.zip")!,
                        file: file, what: "test pack")
    }

    private func serving(size: Int64, modified: String?) -> (URL) async throws -> Downloader.RemoteInfo {
        { url in
            Downloader.RemoteInfo(finalURL: url, size: size, acceptsRanges: true,
                                  lastModified: modified)
        }
    }

    // MARK: What counts as news

    func testAStampThatMatchesTheServerIsTheEndOfIt() async throws {
        let pack = try pack()
        CacheStamp(size: 2_000_000, lastModified: "Fri, 04 Sep 2026 12:27:24 GMT", md5: nil)
            .write(besides: pack.file)
        let news = await pack.newer(probe: serving(size: 2_000_000,
                                                   modified: "Fri, 04 Sep 2026 12:27:24 GMT"))
        XCTAssertNil(news)
    }

    func testAServerOfferingSomethingElseIsNews() async throws {
        let pack = try pack()
        CacheStamp(size: 2_000_000, lastModified: "Mon, 17 Aug 2026 15:05:45 GMT", md5: nil)
            .write(besides: pack.file)
        let found = await pack.newer(
            probe: serving(size: 2_500_000, modified: "Fri, 04 Sep 2026 12:27:24 GMT"))
        let news = try XCTUnwrap(found)
        XCTAssertEqual(news.size, 2_500_000)
        XCTAssertEqual(news.published, DataPack.date(of: "Fri, 04 Sep 2026 12:27:24 GMT"))
    }

    /// Packs installed before kmap stamped them: the file's own date stands in.
    func testAPackWithNoStampIsJudgedByItsOwnDate() async throws {
        let downloaded = DataPack.date(of: "Sun, 30 Aug 2026 00:00:00 GMT")!
        let old = try pack(downloaded: downloaded)
        let older = await old.newer(probe: serving(size: 2_000_000,
                                                   modified: "Fri, 21 Aug 2026 12:00:00 GMT"))
        XCTAssertNil(older, "published before it was fetched — this is that pack")
        let newer = await old.newer(probe: serving(size: 2_000_000,
                                                   modified: "Fri, 04 Sep 2026 12:00:00 GMT"))
        XCTAssertNotNil(newer, "published after it was fetched — a newer one exists")
    }

    /// A mirror with no date and the same size has said nothing worth 2 GB.
    func testASilentServerIsNotNews() async throws {
        let pack = try pack()
        let news = await pack.newer(probe: serving(size: 2_000_000, modified: nil))
        XCTAssertNil(news)
    }

    func testAnUnreachableServerIsNotNewsEither() async throws {
        let pack = try pack()
        struct Offline: Error {}
        let news = await pack.newer(probe: { _ in throw Offline() })
        XCTAssertNil(news)
    }

    func testAPackNobodyInstalledIsNotChecked() async throws {
        let missing = DataPack(id: "test",
                               url: URL(string: "https://example.invalid/pack.zip")!,
                               file: folder.appendingPathComponent("absent.zip"),
                               what: "test pack")
        var asked = false
        _ = await missing.newer(probe: { url in
            asked = true
            return Downloader.RemoteInfo(finalURL: url, size: 1, acceptsRanges: false,
                                         lastModified: nil)
        })
        XCTAssertFalse(asked, "an uninstalled pack is a choice, not an omission")
    }

    // MARK: Which packs a build reads at all

    private func build(sea: Bool, index: Bool) -> BuildPipeline {
        let settings = SettingsStore()
        let toolchain = Toolchain(settings: settings)
        let region = Region(id: "continent/small-region", name: "Small Region",
                            parentID: nil, pbfURL: nil, bbox: .empty, boxes: [])
        let style = MapStyle(id: "plain", name: "Plain", summary: "", origin: .builtin,
                             styleDirectory: nil, typURL: nil, familyID: 6300, productID: 1)
        var recipe = BuildRecipe(region: region, style: style,
                                 outputDirectory: URL(fileURLWithPath: NSTemporaryDirectory()))
        recipe.generateSea = sea
        recipe.searchIndex = index
        return BuildPipeline(recipe: recipe, settings: settings, toolchain: toolchain,
                             styles: StyleCatalog(settings: settings, toolchain: toolchain))
    }

    /// The boundaries reach mkgmap through the index options alone; with no index the map
    /// carries no address, and nothing would read them.
    func testABuildWithNoSearchIndexNeverAsksAboutTheBoundaries() {
        XCTAssertFalse(build(sea: true, index: false).dataPacksInUse.contains(.bounds))
        XCTAssertFalse(build(sea: false, index: false).dataPacksInUse.contains(.bounds))
    }

    /// The coastlines are read only where the build draws its own sea.
    func testABuildThatDrawsNoSeaNeverAsksAboutTheCoastlines() {
        XCTAssertFalse(build(sea: false, index: true).dataPacksInUse.contains(.sea))
    }

    /// Nothing uninstalled is ever asked about.
    func testOnlyInstalledPacksAreEverAsked() {
        for pack in build(sea: true, index: true).dataPacksInUse {
            XCTAssertTrue(pack.isInstalled, pack.id)
        }
    }

    // MARK: How often the question is asked

    func testEveryBuildAsksEveryTimeAndNeverAsksNever() {
        let now = Date()
        XCTAssertFalse(ToolchainUpdates.everyBuild.stillGood(checked: now, now: now),
                       "asked again even a second later")
        XCTAssertTrue(ToolchainUpdates.never.stillGood(checked: nil, now: now),
                      "never asked at all, so any answer still stands")
    }

    func testAnIntervalHoldsUntilItHasPassed() {
        let now = Date()
        let cadence = ToolchainUpdates.monthly
        XCTAssertTrue(cadence.stillGood(checked: now.addingTimeInterval(-29 * 24 * 3600),
                                        now: now))
        XCTAssertFalse(cadence.stillGood(checked: now.addingTimeInterval(-31 * 24 * 3600),
                                         now: now))
        // Never asked before is not the same as asked long ago, but it asks the same way.
        XCTAssertFalse(cadence.stillGood(checked: nil, now: now))
    }

    func testTheIntervalsAreTheOnesTheSettingOffers() {
        let day = 24.0 * 3600
        XCTAssertEqual(ToolchainUpdates.allCases.map(\.interval),
                       [0, 7 * day, 30 * day, 182 * day, 365 * day, nil])
        // The order the dropdown lists them in: most often first, never last.
        XCTAssertEqual(ToolchainUpdates.allCases.map(\.rawValue),
                       ["everyBuild", "weekly", "monthly", "halfYear", "year", "never"])
    }

    func testTheStoredSettingSurvivesAWriteAndReadsBackAsItself() throws {
        var settings = Settings.default
        XCTAssertEqual(settings.toolchainUpdates, .monthly, "the shipped cadence")
        settings.toolchainUpdates = .halfYear
        settings.dataChecked["sea"] = Date(timeIntervalSince1970: 1_000_000)
        let data = try JSONEncoder().encode(settings)
        let back = try JSONDecoder().decode(Settings.self, from: data)
        XCTAssertEqual(back.toolchainUpdates, .halfYear)
        XCTAssertEqual(back.dataChecked["sea"], Date(timeIntervalSince1970: 1_000_000))
    }

    /// A settings file written before this setting existed still reads.
    func testAFileFromBeforeTheSettingReadsAsTheDefault() throws {
        let older = Data(#"{"outputDirectory":"/tmp","maxNodesPerTile":1200000}"#.utf8)
        let read = try XCTUnwrap(SettingsStore.decode(older))
        XCTAssertEqual(read.toolchainUpdates, .monthly)
        XCTAssertTrue(read.dataChecked.isEmpty)
    }

    // MARK: The stage

    func testTheStageIsMarkedDoneWithNothingToDoRatherThanLeftPending() async throws {
        let build = build(sea: false, index: false)
        try await build.updateDataPacks()
        let stage = build.snapshot().stages.first { $0.id == .dataUpdate }
        XCTAssertEqual(stage?.status, .skipped, "this build reads neither pack")
    }

    /// A fetching stage is a running stage: without that it draws as a pending dot with a
    /// bar under it and no spinner, however much is moving.
    func testTheStageRunsWhileItFetchesAndSaysSoWhenItCannot() async throws {
        let build = build(sea: false, index: false)
        let unreachable = DataPack(id: "sea",
                                   url: URL(string: "https://kmap.invalid/pack.zip")!,
                                   file: folder.appendingPathComponent("pack.zip"),
                                   what: "test pack")
        build.pendingPackUpdates = [(unreachable, DataPack.News(size: 10, lastModified: nil,
                                                                published: nil))]
        try await build.updateDataPacks()

        let stage = try XCTUnwrap(build.snapshot().stages.first { $0.id == .dataUpdate })
        XCTAssertNotNil(stage.startedAt, "the stage was marked running before fetching")
        XCTAssertEqual(stage.status, .done, "a mirror that will not answer is not a failed build")
        XCTAssertEqual(stage.detail, t("kept what was already here"))
    }

    /// Ctrl+C during the fetch ends the build, and the stage is crossed out rather than
    /// dashed: the axe fell on it.
    func testCancellingDuringTheFetchStopsTheBuildAndCrossesTheStageOut() async throws {
        let build = build(sea: false, index: false)
        build.set(.dataUpdate, .running, "fetching")
        build.pendingPackUpdates = [(.sea, DataPack.News(size: 10, lastModified: nil,
                                                         published: nil))]
        build.cancel()
        do {
            try await build.updateDataPacks()
            XCTFail("a cancelled build carried on into the next stage")
        } catch is CancellationError {
            build.finish(error: CancellationError())
        }
        let after = build.snapshot()
        XCTAssertTrue(after.cancelled)
        XCTAssertEqual(after.stages.first { $0.id == .dataUpdate }?.status, .failed)
    }

    /// The check every stage boundary makes. Without it a stage that ends early for its
    /// own reasons — a killed tool, a dropped download — lets the next one start, which is
    /// how a cancelled build reached mkgmap.
    func testACancelledBuildStopsAtTheNextStageBoundary() throws {
        let build = build(sea: false, index: false)
        XCTAssertNoThrow(try build.stopIfCancelled())
        build.cancel()
        XCTAssertThrowsError(try build.stopIfCancelled()) { error in
            XCTAssertTrue(error is CancellationError)
        }
    }

    func testTheStageSitsBetweenTheToolCheckAndTheDownload() {
        let order = BuildPipeline.StageID.allCases
        XCTAssertEqual(order.firstIndex(of: .dataUpdate),
                       order.firstIndex(of: .preflight).map { $0 + 1 })
        XCTAssertEqual(order.firstIndex(of: .download),
                       order.firstIndex(of: .dataUpdate).map { $0 + 1 })
    }
}
