import XCTest

@testable import kmap

final class BuildPipelineLifecycleTests: XCTestCase {
    /// The elevation task is unstructured and a cancelled task is not released from a
    /// wait on it, so `cancel()` must reach it by hand.
    func testCancellingReachesTheElevationTaskAndEveryDownloader() async {
        let build = PipelineFixture.pipeline()
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
        let build = PipelineFixture.pipeline()
        build.cancel()
        let elevation = Task<[URL], Error> {
            try await Task.sleep(nanoseconds: 60_000_000_000)
            return []
        }
        build.retain(elevation: elevation)
        XCTAssertTrue(elevation.isCancelled, "the two can race")
    }

    func testStopAskedFlipsWhenTheBuildIsCancelled() {
        let build = PipelineFixture.pipeline()
        let asked = build.stopAsked
        XCTAssertFalse(asked())
        build.cancel()
        XCTAssertTrue(asked(), "what the splitter reads between blobs")
    }

    /// A failed build waits for the elevation before letting go of its lock.
    func testSettlingTheElevationTellsItsThreadsToStop() async {
        let build = PipelineFixture.pipeline()
        let asked = build.stopAsked
        let elevation = Task<[URL], Error>.detached { () async throws -> [URL] in
            // Stands for threads that see only `asked`, not the cancel.
            for _ in 0..<1000 where !asked() { try? await Task.sleep(nanoseconds: 10_000_000) }
            return asked() ? [] : [URL(fileURLWithPath: "/never-told")]
        }
        build.retain(elevation: elevation)
        await build.settleElevation(puttingStagesBack: false)
        let told = try? await elevation.value
        XCTAssertEqual(told, [], "the threads were told to stop")
        XCTAssertFalse(asked(), "and the build is not left reading as cancelled")
    }

    // MARK: How a build that stopped says where it stopped

    func testTheStageAFailureHappenedInIsMarked() {
        let build = PipelineFixture.pipeline()
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
        let build = PipelineFixture.pipeline()
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
        let build = PipelineFixture.pipeline()
        build.set(.compile, .running, "compiling")
        build.cancel()
        build.finish(error: CancellationError())

        let after = build.snapshot()
        XCTAssertEqual(after.stages.first { $0.id == .compile }?.status, .failed)
        XCTAssertTrue(after.cancelled)
    }

    func testABuildThatEndedWellLeavesNoCrossesBehind() {
        let build = PipelineFixture.pipeline()
        build.set(.preflight, .done, "ready")
        build.finish(error: nil)

        let after = build.snapshot()
        XCTAssertNil(after.stages.first { $0.status == .failed })
        XCTAssertNil(after.failure)
    }
}
