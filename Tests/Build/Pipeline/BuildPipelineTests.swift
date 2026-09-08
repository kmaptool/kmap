import XCTest
@testable import kmap

/// The progress bar a build is watched through. A stage is several pieces of work in a
/// row, each counting from its own beginning, and the overall bar never goes backwards.
final class BuildPipelineTests: XCTestCase {

    private func stage(_ id: BuildPipeline.StageID,
                       _ status: BuildPipeline.StageStatus = .pending,
                       fraction: Double? = nil) -> BuildPipeline.Stage {
        var out = BuildPipeline.Stage(id: id)
        out.status = status
        out.fraction = fraction
        return out
    }

    private func snapshot(_ stages: [BuildPipeline.Stage]) -> BuildPipeline.Snapshot {
        BuildPipeline.Snapshot(stages: stages, finished: false, failure: nil, cancelled: false,
                               outputs: [], startedAt: Date(), finishedAt: nil)
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
        XCTAssertEqual(BuildPipeline.StageID.allCases.count, 7)
        // The order is the order the build runs in, which is the order they are drawn.
        XCTAssertEqual(BuildPipeline.StageID.allCases.map(\.rawValue),
                       ["preflight", "download", "elevation", "elevationBuild",
                        "split", "compile", "collect"])
    }

    // MARK: The whole build

    func testNothingStartedIsNoProgressAndEverythingDoneIsAllOfIt() {
        XCTAssertEqual(snapshot(BuildPipeline.StageID.allCases.map { stage($0) }).overall, 0)
        XCTAssertEqual(snapshot(BuildPipeline.StageID.allCases.map { stage($0, .done) })
                        .overall, 1, accuracy: 1e-9)
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
                XCTAssertGreaterThanOrEqual(now, last - 1e-9,
                                            "\(id.rawValue) at \(step): \(now) after \(last)")
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
        stages[1] = stage(.download, .done)
        stages[2] = stage(.elevation, .running, fraction: 0.5)
        stages[3] = stage(.elevationBuild, .running, fraction: 0.25)
        let both = snapshot(stages).overall
        XCTAssertEqual(both, 0.01 + 0.24 + 0.20 * 0.5 + 0.10 * 0.25, accuracy: 1e-9)

        // And finishing one while the other runs only ever moves it forwards.
        stages[2] = stage(.elevation, .done)
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
        XCTAssertEqual(snapshot(stages).overall, 0.01 + 0.24 + 0.20 + 0.10 + 0.15,
                       accuracy: 1e-9)
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

    /// A pipeline far enough along to have a stage running.
    private func pipeline() -> BuildPipeline {
        let settings = SettingsStore()
        let toolchain = Toolchain(settings: settings)
        let region = Region(id: "continent/small-region", name: "Small Region",
                            parentID: nil, pbfURL: nil, bbox: .empty, boxes: [])
        let style = MapStyle(id: "plain", name: "Plain", summary: "", origin: .builtin,
                             styleDirectory: nil, typURL: nil, familyID: 6300, productID: 1)
        let recipe = BuildRecipe(region: region, style: style,
                                 outputDirectory: URL(fileURLWithPath: NSTemporaryDirectory()))
        return BuildPipeline(recipe: recipe, settings: settings, toolchain: toolchain,
                             styles: StyleCatalog(settings: settings, toolchain: toolchain))
    }

    func testTheStageAFailureHappenedInIsMarked() {
        let build = pipeline()
        build.set(.download, .running, "downloading")
        build.finish(error: DownloadError.badStatus(502))

        let after = build.snapshot()
        XCTAssertNil(after.stages.first { $0.status == .running },
                     "nothing may still be spinning once the build is over")
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
        XCTAssertEqual(after.stages.first { $0.id == .preflight }?.status, .done,
                       "a stage that finished did not fail because a later one did")
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
}

/// The whole build's bar only ever moves forward: a running stage without a fraction is
/// guessed at a third done, and the guess must not be taken back when the first real
/// fraction arrives.
final class OverallProgressTests: XCTestCase {
    func testOverallNeverMovesBackwards() {
        let settings = SettingsStore()
        let toolchain = Toolchain(settings: settings)
        let region = Region(id: "continent/small-region", name: "Small Region",
                            parentID: nil, pbfURL: nil, bbox: .empty, boxes: [])
        let style = MapStyle(id: "plain", name: "Plain", summary: "", origin: .builtin,
                             styleDirectory: nil, typURL: nil, familyID: 6300, productID: 1)
        let recipe = BuildRecipe(region: region, style: style,
                                 outputDirectory: URL(fileURLWithPath: NSTemporaryDirectory()))
        let pipeline = BuildPipeline(recipe: recipe, settings: settings,
                                     toolchain: toolchain,
                                     styles: StyleCatalog(settings: settings,
                                                          toolchain: toolchain))
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
        XCTAssertGreaterThanOrEqual(measured.overall, guessed,
                                    "the bar must not move backwards")
        // And it still moves forward from there.
        pipeline.detail(.compile, "13/13 tile(s)", fraction: 0.9)
        XCTAssertGreaterThan(pipeline.snapshot().overall, guessed)
    }
}
