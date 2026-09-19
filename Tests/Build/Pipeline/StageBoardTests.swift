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
}
