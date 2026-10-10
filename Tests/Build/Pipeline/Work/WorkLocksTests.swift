import XCTest

@testable import kmap

final class WorkLocksTests: XCTestCase {
    /// It lies among kmap's locks, where locking works, whatever volume the work folder is on.
    func testTheBuildLockGoesWithTheWorkFolder() throws {
        let work = try scratchFolder()
        let build = PipelineFixture.pipeline(workRoot: work)
        XCTAssertEqual(build.buildLock.deletingLastPathComponent(), Paths.locks)
        Paths.ensure(Paths.locks)
        let held = try XCTUnwrap(HeldLock(trying: build.buildLock))
        XCTAssertNil(
            HeldLock(trying: PipelineFixture.pipeline(workRoot: work).buildLock),
            "another build of the region waits"
        )
        XCTAssertNotNil(
            HeldLock(trying: PipelineFixture.pipeline(workRoot: try scratchFolder()).buildLock),
            "one elsewhere does not"
        )
        withExtendedLifetime(held) {}
    }

    func testBuildsLandingInOneFolderShareItsLock() throws {
        let one = PipelineFixture.pipeline(workRoot: try scratchFolder()),
            other = PipelineFixture.pipeline(workRoot: try scratchFolder())
        XCTAssertNotEqual(one.buildLock, other.buildLock)
        XCTAssertEqual(one.outputLock, other.outputLock)
        XCTAssertEqual(one.outputLock.deletingLastPathComponent(), Paths.locks, "not in the folder of maps")
    }

    func testABuildRefusesAnOutputFolderAnotherHolds() async throws {
        let build = PipelineFixture.pipeline(workRoot: try scratchFolder())
        Paths.ensure(Paths.locks)
        let held = try XCTUnwrap(HeldLock(trying: build.outputLock))
        await build.run()
        withExtendedLifetime(held) {}
        XCTAssertEqual(
            build.snapshot().failure,
            ErrorWords.of(BuildError.outputInUse(Paths.display(build.recipe.destinationDirectory)))
        )
    }

    /// So 1 output folder has 1 lock.
    func testAFolderResolvesAlikeBeforeAndAfterItIsMade() throws {
        let folder = try scratchFolder().appendingPathComponent("out/2026-10-05")
        let before = BuildPipeline.resolvedPath(folder)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        XCTAssertEqual(before, BuildPipeline.resolvedPath(folder))
    }

    /// Run as if 3 days on: touching a held lock's time is refused on Windows.
    func testOldFolderLocksAreSweptButNotOneHeld() throws {
        let locks = try scratchFolder()
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
        try FileDates.setModified(
            locks.appendingPathComponent("output-fresh.lock"),
            to: later.addingTimeInterval(-3600)
        )
        BuildPipeline.removeOldLocks(in: locks, now: later)
        withExtendedLifetime(held) {}
        XCTAssertEqual(
            Set(try FileManager.default.contentsOfDirectory(atPath: locks.path)),
            ["output-b.lock", "tools-in-use.lock", "output-fresh.lock"]
        )
    }
}
