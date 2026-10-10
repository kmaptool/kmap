import XCTest

@testable import kmap

/// A stage is several pieces of work in a row, each counting from its own beginning.
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
        // nil shows a spinner; 0 reads as stuck.
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
        // The order the build runs in, which is the order they are drawn.
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
        // Sitting where the last finished stage left it reads as stopped.
        let stages = BuildPipeline.StageID.allCases.map {
            stage($0, $0 == .compile ? .running : ($0 == .collect ? .pending : .done))
        }
        let overall = snapshot(stages).overall
        XCTAssertGreaterThan(overall, 0.7)
        XCTAssertLessThan(overall, 1)
    }

    func testTwoStagesCanBeRunningAtOnceWithoutConfusingTheBar() {
        var stages = BuildPipeline.StageID.allCases.map { stage($0) }
        stages[0] = stage(.preflight, .done)
        stages[1] = stage(.dataUpdate, .done)
        stages[2] = stage(.download, .done)
        stages[3] = stage(.elevation, .running, fraction: 0.5)
        stages[4] = stage(.elevationBuild, .running, fraction: 0.25)
        let both = snapshot(stages).overall
        XCTAssertEqual(both, 0.01 + 0.01 + 0.23 + 0.20 * 0.5 + 0.10 * 0.25, accuracy: 1e-9)

        stages[3] = stage(.elevation, .done)
        XCTAssertGreaterThan(snapshot(stages).overall, both)
    }

    func testTheTwoHalvesOfElevationAddUpToWhatTheOneStageWasWorth() {
        let fetched = snapshot([stage(.elevation, .done)]).overall
        let builtToo = snapshot([stage(.elevation, .done), stage(.elevationBuild, .done)]).overall
        XCTAssertEqual(builtToo, 0.30, accuracy: 1e-9)
        XCTAssertGreaterThan(builtToo, fetched)
    }

    func testAFailedStageDoesNotCountTowardsProgress() {
        let stages = BuildPipeline.StageID.allCases.map {
            stage($0, $0 == .compile ? .failed : ($0 == .collect ? .pending : .done))
        }
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
        // mkgmap is about 2/3 of a small build's wall clock; download and elevation
        // are most of the rest.
        let mkgmapOnly = snapshot([stage(.compile, .done)]).overall
        let downloadOnly = snapshot([stage(.download, .done)]).overall
        let collectOnly = snapshot([stage(.collect, .done)]).overall
        XCTAssertGreaterThan(mkgmapOnly, downloadOnly)
        XCTAssertGreaterThan(downloadOnly, collectOnly)
    }

    // MARK: The extract a build reads

    /// Whatever another kmap moves into the cache meanwhile; the hold goes with the build.
    func testABuildReadsTheExtractItStartedWith() throws {
        let build = PipelineFixture.pipeline(workRoot: try scratchFolder())
        let cache = try scratchFolder()
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

    // MARK: Putting the outputs in place

    func testANewFolderTakesTheEarlierOnesPlaceAndNothingIsLeftBeside() throws {
        let folder = try scratchFolder()
        let build = PipelineFixture.pipeline()
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

    /// The swap's own way back is tested in `FileWriteTests`.
    func testANewOutputThatCannotBeWrittenLeavesTheEarlierOneWhole() throws {
        #if os(Windows)
        throw XCTSkip("a read-only folder still takes new files here")
        #else
        try XCTSkipIf(getuid() == 0, "root writes into a read-only folder")
        let folder = try scratchFolder()
        let build = PipelineFixture.pipeline()
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

    /// Otherwise a receiver would show the new first part beside the earlier second one.
    func testASetIsPutInWholeOrNotAtAll() throws {
        let folder = try scratchFolder()
        let build = PipelineFixture.pipeline()
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
        let folder = try scratchFolder()
        let build = PipelineFixture.pipeline()
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
}

/// A running stage without a fraction is guessed at 1/3 done, and the guess must not be
/// taken back when the first real fraction arrives.
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
        pipeline.set(.compile, .running, "preparing style")
        let guessed = pipeline.snapshot().overall
        pipeline.detail(.compile, "0/13 tile(s)", fraction: 0)
        let measured = pipeline.snapshot()
        XCTAssertLessThan(measured.rawOverall, guessed, "the dip this test is about")
        XCTAssertGreaterThanOrEqual(
            measured.overall,
            guessed,
            "the bar must not move backwards"
        )
        pipeline.detail(.compile, "13/13 tile(s)", fraction: 0.9)
        XCTAssertGreaterThan(pipeline.snapshot().overall, guessed)
    }

    /// Boxes overlap along a border; a shared degree is traced once, over both pieces.
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
