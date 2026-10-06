import XCTest

@testable import kmap

/// The progress bar a build is watched through. A stage is several pieces of work in a
/// row, each counting from its own beginning, and the overall bar never goes backwards.
final class BuildPipelineTests: XCTestCase {
    private func stage(
        _ id: BuildPipeline.StageID,
        _ status: BuildPipeline.StageStatus = .pending,
        fraction: Double? = nil
    ) -> BuildPipeline.Stage {
        var out = BuildPipeline.Stage(id: id)
        out.status = status
        out.fraction = fraction
        return out
    }

    private func snapshot(_ stages: [BuildPipeline.Stage]) -> BuildPipeline.Snapshot {
        BuildPipeline.Snapshot(
            stages: stages,
            finished: false,
            failure: nil,
            cancelled: false,
            outputs: [],
            startedAt: Date(),
            finishedAt: nil
        )
    }

    // MARK: One stage

    func testTheBarOnlyEverMovesForwards() {
        var one = stage(.elevation, .running)
        one.advance(to: 0.4)
        XCTAssertEqual(one.fraction, 0.4)
        // The next piece of work inside the stage counts from its own beginning.
        one.advance(to: 0.1)
        XCTAssertEqual(one.fraction, 0.4)
        one.advance(to: 0.75)
        XCTAssertEqual(one.fraction, 0.75)
    }

    func testItIsClampedToTheEndOfTheStage() {
        var one = stage(.split, .running)
        one.advance(to: 4)
        XCTAssertEqual(one.fraction, 1)
        one.advance(to: 9)
        XCTAssertEqual(one.fraction, 1)
    }

    func testAStageThatHasNotSaidAnythingYetShowsNoPercentage() {
        // nil means no meaningful percentage and shows a spinner; zero reads as stuck.
        XCTAssertNil(stage(.download, .running).fraction)
        var one = stage(.download, .running)
        one.advance(to: 0)
        XCTAssertEqual(one.fraction, 0)
    }

    func testEveryStageHasSomethingToCallItself() {
        for id in BuildPipeline.StageID.allCases {
            XCTAssertFalse(id.title.isEmpty, id.rawValue)
        }
        XCTAssertEqual(BuildPipeline.StageID.allCases.count, 8)
        // The order is the order the build runs in, which is the order they are drawn.
        XCTAssertEqual(
            BuildPipeline.StageID.allCases.map(\.rawValue),
            [
                "preflight", "dataUpdate", "download", "elevation", "elevationBuild",
                "split", "compile", "collect"
            ]
        )
    }

    // MARK: The whole build

    func testNothingStartedIsNoProgressAndEverythingDoneIsAllOfIt() {
        XCTAssertEqual(snapshot(BuildPipeline.StageID.allCases.map { stage($0) }).overall, 0)
        XCTAssertEqual(
            snapshot(BuildPipeline.StageID.allCases.map { stage($0, .done) })
                .overall,
            1,
            accuracy: 1e-9
        )
    }

    func testASkippedStageCountsAsDoneAndNotAsMissing() {
        // A skipped stage's weight is still claimed, or a finished build stops short.
        let stages = BuildPipeline.StageID.allCases.map {
            stage($0, $0 == .elevation ? .skipped : .done)
        }
        XCTAssertEqual(snapshot(stages).overall, 1, accuracy: 1e-9)
    }

    func testTheBarNeverGoesBackwardsAsTheBuildWalksThroughIt() {
        // The whole sequence, stage by stage and part-way through each.
        var stages = BuildPipeline.StageID.allCases.map { stage($0) }
        var last = 0.0
        for (index, id) in BuildPipeline.StageID.allCases.enumerated() {
            for step in [0.0, 0.3, 0.6, 1.0] {
                stages[index] = stage(id, .running, fraction: step)
                let now = snapshot(stages).overall
                XCTAssertGreaterThanOrEqual(
                    now,
                    last - 1e-9,
                    "\(id.rawValue) at \(step): \(now) after \(last)"
                )
                last = now
            }
            stages[index] = stage(id, .done)
            let now = snapshot(stages).overall
            XCTAssertGreaterThanOrEqual(now, last - 1e-9, "\(id.rawValue) done")
            last = now
        }
        XCTAssertEqual(last, 1, accuracy: 1e-9)
    }

    func testARunningStageWithNothingToSayStillShowsSomeMovement() {
        // Rather than sitting where the last finished stage left it, which reads as stopped.
        let stages = BuildPipeline.StageID.allCases.map {
            stage($0, $0 == .compile ? .running : ($0 == .collect ? .pending : .done))
        }
        let overall = snapshot(stages).overall
        XCTAssertGreaterThan(overall, 0.7)
        XCTAssertLessThan(overall, 1)
    }

    func testTwoStagesCanBeRunningAtOnceWithoutConfusingTheBar() {
        // Fetching elevation and building from what has arrived may run at once; each
        // stage contributes its own share.
        var stages = BuildPipeline.StageID.allCases.map { stage($0) }
        stages[0] = stage(.preflight, .done)
        stages[1] = stage(.dataUpdate, .done)
        stages[2] = stage(.download, .done)
        stages[3] = stage(.elevation, .running, fraction: 0.5)
        stages[4] = stage(.elevationBuild, .running, fraction: 0.25)
        let both = snapshot(stages).overall
        XCTAssertEqual(both, 0.01 + 0.01 + 0.23 + 0.20 * 0.5 + 0.10 * 0.25, accuracy: 1e-9)

        // And finishing one while the other runs only ever moves it forwards.
        stages[3] = stage(.elevation, .done)
        XCTAssertGreaterThan(snapshot(stages).overall, both)
    }

    func testTheTwoHalvesOfElevationAddUpToWhatTheOneStageWasWorth() {
        // Splitting the stage does not change what finished elevation is worth.
        let fetched = snapshot([stage(.elevation, .done)]).overall
        let builtToo = snapshot([stage(.elevation, .done), stage(.elevationBuild, .done)]).overall
        XCTAssertEqual(builtToo, 0.30, accuracy: 1e-9)
        XCTAssertGreaterThan(builtToo, fetched)
    }

    func testAFailedStageDoesNotCountTowardsProgress() {
        let stages = BuildPipeline.StageID.allCases.map {
            stage($0, $0 == .compile ? .failed : ($0 == .collect ? .pending : .done))
        }
        // Everything before it, and nothing for the one that failed.
        XCTAssertEqual(
            snapshot(stages).overall,
            0.01 + 0.24 + 0.20 + 0.10 + 0.15,
            accuracy: 1e-9
        )
    }

    func testTheWeightsAddUpToAWholeBuild() {
        // Otherwise a finished build stops short of the end or claims to be past it.
        let whole = snapshot(BuildPipeline.StageID.allCases.map { stage($0, .done) }).overall
        XCTAssertEqual(whole, 1, accuracy: 1e-9)
    }

    func testCompilingIsWeightedLikeTheTwoThirdsOfABuildItIs() {
        // mkgmap is about two thirds of a small build's wall clock; download and
        // elevation are most of the rest.
        let mkgmapOnly = snapshot([stage(.compile, .done)]).overall
        let downloadOnly = snapshot([stage(.download, .done)]).overall
        let collectOnly = snapshot([stage(.collect, .done)]).overall
        XCTAssertGreaterThan(mkgmapOnly, downloadOnly)
        XCTAssertGreaterThan(downloadOnly, collectOnly)
    }

    // MARK: How a build that stopped says where it stopped

    /// The extract a build reads is the one it started with, whatever another kmap moves
    /// into the cache meanwhile; the hold goes with the build.
    func testABuildReadsTheExtractItStartedWith() throws {
        let build = pipeline(workRoot: try scratch())
        let cache = try scratch()
        let cached = cache.appendingPathComponent("region-a.osm.pbf")
        try FileTools.write(Data("old".utf8), to: cached)
        let pinned = try XCTUnwrap(build.pinning([cached]).first)
        XCTAssertNotEqual(pinned, cached)
        XCTAssertEqual(pinned.lastPathComponent, cached.lastPathComponent)

        let fresh = cache.appendingPathComponent("fresh")
        try FileTools.write(Data("new".utf8), to: fresh)
        try FileTools.replace(cached, with: fresh)
        XCTAssertEqual(try String(contentsOf: pinned, encoding: .utf8), "old")

        build.unpinExtracts()
        XCTAssertFalse(FileTools.exists(pinned))
        XCTAssertEqual(try String(contentsOf: cached, encoding: .utf8), "new")
    }

    private func pipeline(workRoot: URL? = nil, regions: Int = 1) -> BuildPipeline {
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
        var recipe = BuildRecipe(
            region: region,
            style: style,
            outputDirectory: URL(fileURLWithPath: NSTemporaryDirectory())
        )
        if let workRoot { recipe.workRoot = workRoot }
        recipe.extraRegions = (1..<max(1, regions)).map {
            Region(
                id: "continent/region-\($0)",
                name: "Region \($0)",
                parentID: nil,
                pbfURL: nil,
                bbox: .empty,
                boxes: []
            )
        }
        return BuildPipeline(
            recipe: recipe,
            settings: settings,
            toolchain: toolchain,
            styles: StyleCatalog(settings: settings, toolchain: toolchain)
        )
    }

    func testTheStageAFailureHappenedInIsMarked() {
        let build = pipeline()
        build.set(.download, .running, "downloading")
        build.finish(error: DownloadError.badStatus(502))

        let after = build.snapshot()
        XCTAssertNil(
            after.stages.first { $0.status == .running },
            "nothing may still be spinning once the build is over"
        )
        XCTAssertEqual(after.stages.first { $0.id == .download }?.status, .failed)
        XCTAssertNotNil(after.failure)
        XCTAssertFalse(after.cancelled)
    }

    func testTheStagesThatFinishedKeepTheirTicks() {
        let build = pipeline()
        build.set(.preflight, .done, "ready")
        build.set(.download, .running, "downloading")
        build.finish(error: DownloadError.badStatus(502))

        let after = build.snapshot()
        XCTAssertEqual(
            after.stages.first { $0.id == .preflight }?.status,
            .done,
            "a stage that finished did not fail because a later one did"
        )
        XCTAssertEqual(after.stages.first { $0.id == .download }?.status, .failed)
    }

    func testCancellingMarksTheStageTheAxeFellOn() {
        let build = pipeline()
        build.set(.compile, .running, "compiling")
        build.cancel()
        build.finish(error: CancellationError())

        let after = build.snapshot()
        XCTAssertEqual(after.stages.first { $0.id == .compile }?.status, .failed)
        XCTAssertTrue(after.cancelled)
    }

    func testABuildThatEndedWellLeavesNoCrossesBehind() {
        let build = pipeline()
        build.set(.preflight, .done, "ready")
        build.finish(error: nil)

        let after = build.snapshot()
        XCTAssertNil(after.stages.first { $0.status == .failed })
        XCTAssertNil(after.failure)
    }

    // MARK: Who builds where

    /// The lock goes with the work folder: a build with a folder of its own is not held
    /// up by one elsewhere, and 2 sharing a folder are. It lies among kmap's locks, where
    /// locking works, whatever volume the work folder is on.
    func testTheBuildLockGoesWithTheWorkFolder() throws {
        let work = try scratch()
        let build = pipeline(workRoot: work)
        XCTAssertEqual(build.buildLock.deletingLastPathComponent(), Paths.locks)
        Paths.ensure(Paths.locks)
        let held = try XCTUnwrap(HeldLock(trying: build.buildLock))
        XCTAssertNil(HeldLock(trying: pipeline(workRoot: work).buildLock), "another build of the region waits")
        XCTAssertNotNil(HeldLock(trying: pipeline(workRoot: try scratch()).buildLock), "one elsewhere does not")
        withExtendedLifetime(held) {}
    }

    /// The work folder of a failed build goes when this map is built again, and other
    /// maps' after 3 days; a folder kmap did not mark, or one a build holds, stays.
    func testWorkLeftByEarlierBuildsIsClearedButNotWhatIsNotKmaps() throws {
        let work = try scratch()
        let build = pipeline(workRoot: work)
        let own = build.workDirectory
        try FileManager.default.createDirectory(
            at: own.appendingPathComponent("tiles"),
            withIntermediateDirectories: true
        )
        try Data(count: 10).write(to: own.appendingPathComponent("tiles/1.osm.pbf"))
        try Data().write(to: own.appendingPathComponent(BuildPipeline.workMarker))
        let old = Date().addingTimeInterval(-4 * 86_400)
        func folder(_ name: String, marked: Bool, at date: Date) throws -> URL {
            let url = work.appendingPathComponent(name, isDirectory: true)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            try Data(count: 5).write(to: url.appendingPathComponent("tile.img"))
            if marked {
                let marker = url.appendingPathComponent(BuildPipeline.workMarker)
                try Data().write(to: marker)
                try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: marker.path)
            }
            try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: url.path)
            return url
        }
        _ = try folder("gone", marked: true, at: old)
        _ = try folder("fresh", marked: true, at: Date())
        let kept = try folder("kept", marked: true, at: old)
        try Data().write(to: kept.appendingPathComponent(BuildPipeline.keptMarker))
        _ = try folder("users-own", marked: false, at: old)
        let busy = try folder("busy", marked: true, at: old)
        Paths.ensure(Paths.locks)
        let held = try XCTUnwrap(HeldLock(trying: BuildPipeline.lock(BuildPipeline.workLockPrefix, for: busy)))

        try build.clearEarlierWork()
        withExtendedLifetime(held) {}

        XCTAssertEqual(
            Set(FileTools.contents(of: work).map(\.lastPathComponent)),
            [own.lastPathComponent, "fresh", "kept", "users-own", "busy"]
        )
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: own.path), [BuildPipeline.workMarker])
    }

    /// An unmarked work folder under a 3-region map's readable name goes with its next build.
    func testTheEarlierUnmarkedFolderOfABigSetIsCleared() throws {
        let build = pipeline(workRoot: try scratch(), regions: 3)
        let earlier = build.recipe.workRoot.appendingPathComponent(build.recipe.areaSlug)
        XCTAssertNotEqual(build.recipe.areaSlug, build.recipe.slug)
        try FileManager.default.createDirectory(
            at: earlier.appendingPathComponent("tiles"),
            withIntermediateDirectories: true
        )
        try Data().write(to: earlier.appendingPathComponent("tiles/areas.list"))
        try build.clearEarlierWork()
        XCTAssertFalse(FileTools.exists(earlier))
    }

    /// Outside kmap's own work root a folder named as this map's work folder is cleared
    /// only where kmap marked it: one of the user's may have that name.
    func testAFolderOfTheUsersNamedAsTheWorkFolderIsLeftAlone() throws {
        let build = pipeline(workRoot: try scratch())
        try FileManager.default.createDirectory(at: build.workDirectory, withIntermediateDirectories: true)
        try Data("mine".utf8).write(to: build.workDirectory.appendingPathComponent("notes.txt"))
        XCTAssertThrowsError(try build.clearEarlierWork())
        XCTAssertTrue(FileTools.exists(build.workDirectory.appendingPathComponent("notes.txt")))
    }

    /// A work folder an earlier kmap left unmarked, or one cut short before its mark, is
    /// still kmap's to clear.
    func testAnUnmarkedFolderAsKmapLeavesItIsCleared() throws {
        let build = pipeline(workRoot: try scratch())
        try FileManager.default.createDirectory(
            at: build.workDirectory.appendingPathComponent("tiles"),
            withIntermediateDirectories: true
        )
        try Data().write(to: build.workDirectory.appendingPathComponent("annotated.osm.pbf"))
        XCTAssertNoThrow(try build.clearEarlierWork())
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(atPath: build.workDirectory.path),
            [BuildPipeline.workMarker]
        )
        let empty = pipeline(workRoot: try scratch())
        try FileManager.default.createDirectory(at: empty.workDirectory, withIntermediateDirectories: true)
        XCTAssertNoThrow(try empty.clearEarlierWork())
    }

    /// Contours another tool made are not kmap's: a hand-made mkgmap project named as the
    /// map is the user's.
    func testAProjectWithOtherToolsContoursIsLeftAlone() throws {
        let build = pipeline(workRoot: try scratch())
        for name in ["style", "typ", "contours"] {
            try FileManager.default.createDirectory(
                at: build.workDirectory.appendingPathComponent(name),
                withIntermediateDirectories: true
            )
        }
        let phyghtmap = build.workDirectory.appendingPathComponent(
            "contours/lon10.00_11.00lat47.00_48.00_srtm1v3.0.osm.pbf"
        )
        try Data().write(to: phyghtmap)
        XCTAssertThrowsError(try build.clearEarlierWork())
        XCTAssertTrue(FileTools.exists(phyghtmap))
        try Data().write(
            to: build.workDirectory.appendingPathComponent("contours/contour0001.osm.pbf.1a2b3c4d.partial")
        )
        XCTAssertNoThrow(try build.clearEarlierWork(), "with kmap's own, cut short too, it is kmap's")
    }

    /// Names kmap uses are not enough: a hand-made folder of tiles and a style, named as
    /// the map, is the user's.
    func testAFolderWithKmapsNamesButNothingKmapMadeIsLeftAlone() throws {
        let build = pipeline(workRoot: try scratch())
        for name in ["tiles", "style"] {
            try FileManager.default.createDirectory(
                at: build.workDirectory.appendingPathComponent(name),
                withIntermediateDirectories: true
            )
        }
        XCTAssertThrowsError(try build.clearEarlierWork())
        XCTAssertTrue(FileTools.exists(build.workDirectory.appendingPathComponent("tiles")))
    }

    /// 2 builds with work folders of their own still land in 1 output folder, and are
    /// held apart there.
    func testBuildsLandingInOneFolderShareItsLock() throws {
        let one = pipeline(workRoot: try scratch()), other = pipeline(workRoot: try scratch())
        XCTAssertNotEqual(one.buildLock, other.buildLock)
        XCTAssertEqual(one.outputLock, other.outputLock)
        XCTAssertEqual(one.outputLock.deletingLastPathComponent(), Paths.locks, "not in the folder of maps")
    }

    /// A build whose output folder another holds stops before anything else.
    func testABuildRefusesAnOutputFolderAnotherHolds() async throws {
        let build = pipeline(workRoot: try scratch())
        Paths.ensure(Paths.locks)
        let held = try XCTUnwrap(HeldLock(trying: build.outputLock))
        await build.run()
        withExtendedLifetime(held) {}
        XCTAssertEqual(
            build.snapshot().failure,
            ErrorWords.of(BuildError.outputInUse(Paths.display(build.recipe.destinationDirectory)))
        )
    }

    /// A folder not made yet resolves as it will once made, so 1 output folder has 1 lock.
    func testAFolderResolvesAlikeBeforeAndAfterItIsMade() throws {
        let folder = try scratch().appendingPathComponent("out/2026-10-05")
        let before = BuildPipeline.resolvedPath(folder)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        XCTAssertEqual(before, BuildPipeline.resolvedPath(folder))
    }

    /// Folder and download locks of days gone go, unless one is held; kmap's fixed locks
    /// stay. Run as if 3 days on, so the held lock is old without its time touched while
    /// held, which Windows would refuse.
    func testOldFolderLocksAreSweptButNotOneHeld() throws {
        let locks = try scratch()
        let later = Date().addingTimeInterval(3 * 86_400)
        let busy = locks.appendingPathComponent("output-b.lock")
        let held = try XCTUnwrap(HeldLock(trying: busy))
        XCTAssertGreaterThan(
            try XCTUnwrap(FileTools.modified(of: busy)),
            Date().addingTimeInterval(-60),
            "a take says when it was taken"
        )
        for name in ["output-a.lock", "work-a.lock", "download-x.lock", "tools-in-use.lock", "output-fresh.lock"] {
            try Data().write(to: locks.appendingPathComponent(name))
        }
        try FileManager.default.setAttributes(
            [.modificationDate: later.addingTimeInterval(-3600)],
            ofItemAtPath: locks.appendingPathComponent("output-fresh.lock").path
        )
        BuildPipeline.removeOldLocks(in: locks, now: later)
        withExtendedLifetime(held) {}
        XCTAssertEqual(
            Set(try FileManager.default.contentsOfDirectory(atPath: locks.path)),
            ["output-b.lock", "tools-in-use.lock", "output-fresh.lock"]
        )
    }

    // MARK: Putting the outputs in place

    private func scratch() throws -> URL {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("collect-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        return folder
    }

    /// Nothing of the new one's partial or the earlier one set aside stays beside it.
    func testANewFolderTakesTheEarlierOnesPlaceAndNothingIsLeftBeside() throws {
        let folder = try scratch()
        let build = pipeline()
        let earlier = folder.appendingPathComponent("map.gmap", isDirectory: true)
        try FileManager.default.createDirectory(at: earlier, withIntermediateDirectories: true)
        try Data("old".utf8).write(to: earlier.appendingPathComponent("only-in-old"))
        let fresh = folder.appendingPathComponent("fresh", isDirectory: true)
        try FileManager.default.createDirectory(at: fresh, withIntermediateDirectories: true)
        try Data("new".utf8).write(to: fresh.appendingPathComponent("only-in-new"))

        _ = try build.place([(fresh, earlier)])

        XCTAssertTrue(FileManager.default.fileExists(atPath: earlier.appendingPathComponent("only-in-new").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: earlier.appendingPathComponent("only-in-old").path))
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(atPath: folder.path),
            ["map.gmap"],
            "neither the new one's partial nor the earlier one set aside stays"
        )
    }

    /// A folder that takes no new file: the earlier output and the new map both stay. The
    /// swap's own way back is `FileWriteTests`'.
    func testANewOutputThatCannotBeWrittenLeavesTheEarlierOneWhole() throws {
        #if os(Windows)
        throw XCTSkip("a read-only folder still takes new files here")
        #else
        try XCTSkipIf(getuid() == 0, "root writes into a read-only folder")
        let folder = try scratch()
        let build = pipeline()
        let output = folder.appendingPathComponent("out", isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let earlier = output.appendingPathComponent("map.img")
        try Data("old".utf8).write(to: earlier)
        let fresh = folder.appendingPathComponent("fresh.img")
        try Data("new".utf8).write(to: fresh)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: output.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: output.path) }

        XCTAssertThrowsError(try build.place([(fresh, earlier)]))
        XCTAssertEqual(try Data(contentsOf: earlier), Data("old".utf8))
        XCTAssertEqual(try Data(contentsOf: fresh), Data("new".utf8), "the new map is not lost either")
        #endif
    }

    /// A part that cannot be put in takes the parts before it back out: a receiver would
    /// show the new first part beside the earlier second one.
    func testASetIsPutInWholeOrNotAtAll() throws {
        let folder = try scratch()
        let build = pipeline()
        let first = folder.appendingPathComponent("p1.img")
        let second = folder.appendingPathComponent("p2.img")
        try Data("old 1".utf8).write(to: first)
        try Data("old 2".utf8).write(to: second)
        let fresh = folder.appendingPathComponent("fresh-1.img")
        try Data("new 1".utf8).write(to: fresh)
        let missing = folder.appendingPathComponent("never-made.img")

        XCTAssertThrowsError(try build.place([(fresh, first), (missing, second)]))

        XCTAssertEqual(try Data(contentsOf: first), Data("old 1".utf8))
        XCTAssertEqual(try Data(contentsOf: second), Data("old 2".utf8))
        XCTAssertEqual(try Data(contentsOf: fresh), Data("new 1".utf8), "the new part goes back")
        XCTAssertEqual(
            Set(try FileManager.default.contentsOfDirectory(atPath: folder.path)),
            ["p1.img", "p2.img", "fresh-1.img"]
        )
    }

    func testWhatAStoppedBuildLeftBesideItsOutputsIsSweptAndNotCounted() throws {
        let folder = try scratch()
        let build = pipeline()
        let name = build.recipe.fileName()
        let other = build.recipe.fileName(ordinal: 1, of: 2)
        for leftover in [name + ".partial", other + ".old", other, "notes.txt", "notes.txt.old"] {
            try Data().write(to: folder.appendingPathComponent(leftover))
        }
        try Data().write(to: folder.appendingPathComponent(name))

        build.removeEarlierOutputs(
            in: folder,
            keeping: [BuildPipeline.Output(name: name, url: folder.appendingPathComponent(name), size: 0)]
        )

        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted(),
            [name, "notes.txt", "notes.txt.old"],
            "only what names an output of this map goes"
        )
    }

    // MARK: Cancelling reaches everything that is fetching

    /// The elevation task runs beside the split, unstructured: the main task may be
    /// waiting on it, and a cancelled task is not released from a wait. So `cancel()`
    /// has to reach it by hand, along with every downloader still retained.
    func testCancellingReachesTheElevationTaskAndEveryDownloader() async {
        let build = pipeline()
        let elevation = Task<[URL], Error> {
            try await Task.sleep(nanoseconds: 60_000_000_000)
            return []
        }
        build.retain(elevation: elevation)
        let first = Downloader(log: Log()), second = Downloader(log: Log())
        build.retain(first)
        build.retain(second)

        build.cancel()
        XCTAssertTrue(elevation.isCancelled)
        XCTAssertTrue(first.wasCancelled, "the first retained downloader, not only the last")
        XCTAssertTrue(second.wasCancelled)
        do {
            _ = try await elevation.value
            XCTFail("a cancelled wait ends with the cancellation")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
    }

    func testAnElevationTaskRegisteredAfterCancelIsCancelledAtOnce() async {
        let build = pipeline()
        build.cancel()
        let elevation = Task<[URL], Error> {
            try await Task.sleep(nanoseconds: 60_000_000_000)
            return []
        }
        build.retain(elevation: elevation)
        XCTAssertTrue(elevation.isCancelled, "the two can race")
    }

    func testStopAskedFlipsWhenTheBuildIsCancelled() {
        let build = pipeline()
        let asked = build.stopAsked
        XCTAssertFalse(asked())
        build.cancel()
        XCTAssertTrue(asked(), "what the splitter reads between blobs")
    }

    /// A failed build waits for the elevation before letting go of its lock, and the
    /// elevation's own threads see only `stopAsked`.
    func testSettlingTheElevationTellsItsThreadsToStop() async {
        let build = pipeline()
        let asked = build.stopAsked
        let elevation = Task<[URL], Error>.detached { () async throws -> [URL] in
            // Not ended by the cancel itself: the threads it stands for see only `asked`.
            for _ in 0..<1000 where !asked() { try? await Task.sleep(nanoseconds: 10_000_000) }
            return asked() ? [] : [URL(fileURLWithPath: "/never-told")]
        }
        build.retain(elevation: elevation)
        await build.settleElevation(puttingStagesBack: false)
        let told = try? await elevation.value
        XCTAssertEqual(told, [], "the threads were told to stop")
        XCTAssertFalse(asked(), "and the build is not left reading as cancelled")
    }
}

/// The whole build's bar only ever moves forward: a running stage without a fraction is
/// guessed at a third done, and the guess must not be taken back when the first real
/// fraction arrives.
final class OverallProgressTests: XCTestCase {
    func testOverallNeverMovesBackwards() {
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
        let recipe = BuildRecipe(
            region: region,
            style: style,
            outputDirectory: URL(fileURLWithPath: NSTemporaryDirectory())
        )
        let pipeline = BuildPipeline(
            recipe: recipe,
            settings: settings,
            toolchain: toolchain,
            styles: StyleCatalog(
                settings: settings,
                toolchain: toolchain
            )
        )
        pipeline.set(.preflight, .done)
        pipeline.set(.download, .done)
        pipeline.set(.elevation, .skipped)
        pipeline.set(.elevationBuild, .skipped)
        pipeline.set(.split, .done)
        // Running with no fraction: guessed at a third of the stage's weight.
        pipeline.set(.compile, .running, "preparing style")
        let guessed = pipeline.snapshot().overall
        // The first real fraction is zero, which would pull the raw figure down.
        pipeline.detail(.compile, "0/13 tile(s)", fraction: 0)
        let measured = pipeline.snapshot()
        XCTAssertLessThan(measured.rawOverall, guessed, "the dip this test is about")
        XCTAssertGreaterThanOrEqual(
            measured.overall,
            guessed,
            "the bar must not move backwards"
        )
        // And it still moves forward from there.
        pipeline.detail(.compile, "13/13 tile(s)", fraction: 0.9)
        XCTAssertGreaterThan(pipeline.snapshot().overall, guessed)
    }

    /// 2 regions' boxes overlap along their border: a degree they share is traced once,
    /// over both their pieces of it.
    func testADegreeTwoRegionsShareIsOneContourCell() {
        let south = BBox(minLon: 30, minLat: 45.0, maxLon: 31, maxLat: 45.52)
        let north = BBox(minLon: 30, minLat: 45.28, maxLon: 31, maxLat: 46)
        let elsewhere = BBox(minLon: 31, minLat: 45, maxLon: 32, maxLat: 46)
        let cells = BuildPipeline.oneCellPerDegree([south, north, elsewhere])
        XCTAssertEqual(cells.count, 2)
        XCTAssertEqual(cells.first?.minLat, 45.0)
        XCTAssertEqual(cells.first?.maxLat, 46)
    }
}
