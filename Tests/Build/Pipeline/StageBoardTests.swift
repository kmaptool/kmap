import XCTest

@testable import kmap

/// The stages of a build, written by the run and by progress monitors on their own tasks.
final class StageBoardTests: XCTestCase {
    func testEveryStageStartsPendingInTheOrderTheyRun() {
        let board = StageBoard()
        XCTAssertEqual(board.stages.map(\.id), BuildPipeline.StageID.allCases)
        XCTAssertTrue(board.stages.allSatisfy { $0.status == .pending && $0.fraction == nil })
        XCTAssertTrue(board.running.isEmpty)
    }

    func testAStageThatStartsBeginsItsBarAndItsClock() {
        let board = StageBoard()
        board.set(.split, .running, "starting")
        board.detail(.split, "halfway", fraction: 0.5)
        board.set(.split, .running, "still going")
        XCTAssertEqual(board.stages.first { $0.id == .split }?.fraction, 0.5, "already running: the bar stays")
        XCTAssertEqual(board.detail(of: .split), "still going")
        XCTAssertEqual(board.running, [.split])

        board.set(.split, .done)
        board.set(.split, .running, "again, after a re-split")
        XCTAssertNil(board.stages.first { $0.id == .split }?.fraction, "a restart begins from here")
        XCTAssertNotNil(board.stages.first { $0.id == .split }?.startedAt)
    }

    func testABarOnlyMovesForwardUntilANewPhaseClearsIt() {
        let board = StageBoard()
        board.set(.download, .running)
        board.advance(.download, fraction: 0.6)
        board.advance(.download, fraction: 0.2)
        board.detail(.download, "text", fraction: 0.4)
        XCTAssertEqual(board.stages.first { $0.id == .download }?.fraction, 0.6)
        board.beginPhase(.download, "verifying")
        XCTAssertNil(board.stages.first { $0.id == .download }?.fraction)
        XCTAssertEqual(board.detail(of: .download), "verifying")
    }

    func testAFinishedStageKnowsHowLongItTook() {
        let board = StageBoard()
        board.set(.compile, .running)
        board.set(.compile, .done, "10 file(s) built")
        let stage = board.stages.first { $0.id == .compile }
        XCTAssertEqual(stage?.status, .done)
        XCTAssertGreaterThanOrEqual(stage?.seconds ?? -1, 0)
        XCTAssertGreaterThan(stage?.peakBytes ?? 0, 0)
    }

    func testAClosedBoardKeepsItsStagesAsTheBuildLeftThem() {
        // The elevation may still wind down after a failed build ends.
        let board = StageBoard()
        board.set(.elevationBuild, .running)
        board.stop("failed")
        board.close()
        board.set(.elevationBuild, .running, "late")
        board.detail(.elevationBuild, "later")
        XCTAssertEqual(board.status(of: .elevationBuild), .failed)
        XCTAssertEqual(board.detail(of: .elevationBuild), "failed")
    }

    func testTheWholeBuildsBarNeverGoesBack() {
        let board = StageBoard()
        XCTAssertEqual(board.floor(raisedTo: 0.4), 0.4)
        XCTAssertEqual(board.floor(raisedTo: 0.1), 0.4)
        XCTAssertEqual(board.floor(raisedTo: 0.7), 0.7)
    }

    func testAMonitorOnItsOwnTaskWritesWhatTheReaderSees() async {
        // What the board exists for: held by a task that does not hold the build.
        let board = StageBoard()
        board.set(.download, .running)
        let monitor = Task {
            for step in 1...100 { board.detail(.download, "step \(step)", fraction: Double(step) / 100) }
        }
        await monitor.value
        XCTAssertEqual(board.detail(of: .download), "step 100")
        XCTAssertEqual(board.stages.first { $0.id == .download }?.fraction, 1)
    }

    func testManyWritersLeaveEveryStageWhole() {
        let board = StageBoard()
        let ids = BuildPipeline.StageID.allCases
        DispatchQueue.concurrentPerform(iterations: 64) { n in
            let id = ids[n % ids.count]
            board.set(id, .running)
            for step in 0..<200 { board.detail(id, "w\(n)", fraction: Double(step) / 200) }
        }
        XCTAssertEqual(Set(board.running), Set(ids))
        XCTAssertTrue(board.stages.allSatisfy { ($0.fraction ?? 0) > 0.99 })
    }

    func testThePipelineReadsAndWritesThroughItsBoard() {
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
        let build = BuildPipeline(
            recipe: BuildRecipe(
                region: region,
                style: style,
                outputDirectory: URL(fileURLWithPath: NSTemporaryDirectory())
            ),
            settings: settings,
            toolchain: toolchain,
            styles: StyleCatalog(settings: settings, toolchain: toolchain)
        )
        build.set(.download, .running, "from the pipeline")
        XCTAssertEqual(build.board.detail(of: .download), "from the pipeline")
        build.board.detail(.download, "from a monitor", fraction: 0.5)
        XCTAssertEqual(build.snapshot().stages.first { $0.id == .download }?.detail, "from a monitor")
        XCTAssertEqual(build.status(of: .download), .running)
    }

    // MARK: Waiting on another stage

    private func split(_ board: StageBoard) -> BuildPipeline.Stage {
        board.stages.first { $0.id == .split }!
    }

    func testAStageHeldUpByAnotherReadsAsWaitingUntilWhatItWaitsForArrives() async {
        let board = StageBoard()
        board.set(.split, .running, "reading the extract")
        let tiles = Gate<Int>()
        let asked = Gate<Bool>()
        let waiter = Task {
            await board.waiting(.split) {
                asked.open(true)
                return await tiles.value
            }
        }
        _ = await asked.value
        XCTAssertTrue(split(board).isWaiting)
        XCTAssertTrue(split(board).isHeld(among: board.stages), "shown as not started")
        XCTAssertEqual(board.status(of: .split), .running, "the stage's clock keeps running")

        tiles.open(7)
        let got = await waiter.value
        XCTAssertEqual(got, 7)
        XCTAssertFalse(split(board).isWaiting)
        XCTAssertFalse(split(board).isHeld(among: board.stages))
        XCTAssertEqual(split(board).detail, "reading the extract")
    }

    func testAStageWaitsWhileAnyOfItsLanesDoes() async {
        let board = StageBoard()
        board.set(.split, .running, "reading the extract")
        let first = Gate<Int>(), second = Gate<Int>()
        let asked = [Gate<Bool>(), Gate<Bool>()]
        let waiters = [first, second].enumerated().map { index, gate in
            Task {
                await board.waiting(.split) {
                    asked[index].open(true)
                    return await gate.value
                }
            }
        }
        for gate in asked { _ = await gate.value }
        // Another lane reporting its work does not hide the wait.
        board.detail(.split, "region 2: scanned")
        XCTAssertTrue(split(board).isWaiting)
        first.open(1)
        _ = await waiters[0].value
        XCTAssertTrue(split(board).isWaiting, "the second lane still waits")
        second.open(2)
        _ = await waiters[1].value
        XCTAssertFalse(split(board).isWaiting)
        XCTAssertEqual(split(board).detail, "region 2: scanned")
    }

    func testAWaitThatThrowsStillEnds() async {
        struct Lost: Error {}
        let board = StageBoard()
        board.set(.split, .running, "reading the extract")
        do {
            try await board.waiting(.split) { throw Lost() }
            XCTFail("the error must pass through")
        } catch {}
        XCTAssertFalse(split(board).isWaiting)
    }

    func testOnlyARunningStageReadsAsWaiting() async {
        let board = StageBoard()
        let asked = Gate<Bool>(), release = Gate<Bool>()
        let waiter = Task {
            await board.waiting(.split) {
                asked.open(true)
                return await release.value
            }
        }
        _ = await asked.value
        XCTAssertFalse(split(board).isWaiting, "a stage that has not started is pending, not waiting")
        board.set(.split, .failed, "stopped")
        XCTAssertEqual(split(board).detail, "stopped")
        release.open(true)
        _ = await waiter.value
    }

    func testTheSplitReadsAsNotStartedWhileElevationStillDownloads() {
        let board = StageBoard()
        board.set(.elevation, .running, "fetching")
        board.set(.split, .running, "reading the extract")
        XCTAssertTrue(split(board).isHeld(among: board.stages))
        let elevation = board.stages.first { $0.id == .elevation }!
        XCTAssertFalse(elevation.isHeld(among: board.stages), "the download itself is at work")

        board.set(.elevation, .done)
        XCTAssertFalse(split(board).isHeld(among: board.stages))
        board.set(.split, .done)
        XCTAssertFalse(split(board).isHeld(among: board.stages), "a finished stage is not held")
    }

    func testAWaitingStageIsHeldWhateverElevationDoes() async {
        let board = StageBoard()
        board.set(.elevation, .done)
        board.set(.split, .running, "reading the extract")
        let asked = Gate<Bool>(), release = Gate<Bool>()
        let waiter = Task {
            await board.waiting(.split) {
                asked.open(true)
                return await release.value
            }
        }
        _ = await asked.value
        XCTAssertTrue(split(board).isHeld(among: board.stages))
        release.open(true)
        _ = await waiter.value
        XCTAssertFalse(split(board).isHeld(among: board.stages))
    }

    func testAStoppedBuildFailsWhatWorkedAndLeavesAHeldStageNotStarted() {
        let board = StageBoard()
        board.set(.download, .done)
        board.set(.elevation, .running, "fetching")
        board.set(.split, .running, "reading the extract")
        board.stop("cancelled")

        XCTAssertEqual(board.status(of: .elevation), .failed)
        XCTAssertEqual(board.detail(of: .elevation), "cancelled")
        XCTAssertEqual(board.status(of: .split), .pending, "it was never shown as started")
        XCTAssertEqual(board.detail(of: .split), "")
        XCTAssertEqual(board.status(of: .download), .done)
        XCTAssertTrue(board.running.isEmpty)
    }

    func testAStoppedBuildFailsTheSplitOnceItReallyWorks() {
        let board = StageBoard()
        board.set(.elevation, .done)
        board.set(.split, .running, "cutting the tiles")
        board.stop("failed")
        XCTAssertEqual(board.status(of: .split), .failed)
        XCTAssertEqual(board.detail(of: .split), "failed")
    }

    func testTheSplitWaitsOnlyWhenEveryRegionAtWorkWaits() {
        // 2 regions annotated side by side: 1 waiting for the elevation while the other
        // still scans is work, not a wait.
        let board = StageBoard()
        board.set(.elevation, .done)
        board.set(.split, .running, "reading the extract")
        board.beginLane(.split)
        board.beginLane(.split)
        board.beginWaiting(.split)
        XCTAssertFalse(split(board).isHeld(among: board.stages), "the other region still scans")
        board.beginWaiting(.split)
        XCTAssertTrue(split(board).isHeld(among: board.stages), "both wait")
        board.endWaiting(.split)
        board.endLane(.split)
        // The scanning region finished; the one left waits, and so the stage does.
        XCTAssertTrue(split(board).isHeld(among: board.stages))
        board.endWaiting(.split)
        XCTAssertFalse(split(board).isHeld(among: board.stages))
    }
}
