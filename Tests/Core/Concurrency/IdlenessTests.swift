import XCTest

@testable import kmap

/// The split stage reads as waiting only when nothing of the extract is being read:
/// the repair waits for elevation and the scans beside it are done.
final class IdlenessTests: XCTestCase {
    private func watched(jobs: Int) -> (Idleness, Locked<[Bool]>) {
        let said = Locked<[Bool]>([])
        return (Idleness(jobs: jobs) { held in said.withLock { $0.append(held) } }, said)
    }

    func testAWaitBesideWorkingJobsIsNotIdle() {
        let (idleness, said) = watched(jobs: 3)
        idleness.waiting {
            XCTAssertEqual(said.withLock { $0 }, [], "2 scans are still at work")
            idleness.finished()
            XCTAssertEqual(said.withLock { $0 }, [])
            idleness.finished()
            XCTAssertEqual(said.withLock { $0 }, [true], "only the waiting job is left")
        }
        XCTAssertEqual(said.withLock { $0 }, [true, false], "the wait is over: work resumes")
        idleness.finished()
        XCTAssertEqual(said.withLock { $0 }, [true, false])
    }

    func testAWaitAfterTheOthersFinishedIsIdleAtOnce() {
        let (idleness, said) = watched(jobs: 2)
        idleness.finished()
        idleness.waiting { XCTAssertEqual(said.withLock { $0 }, [true]) }
        XCTAssertEqual(said.withLock { $0 }, [true, false])
    }

    func testJobsThatNeverWaitAreNeverIdle() {
        let (idleness, said) = watched(jobs: 2)
        idleness.finished()
        idleness.finished()
        XCTAssertEqual(said.withLock { $0 }, [])
    }

    func testAWaitThatThrowsStillEnds() {
        struct Lost: Error {}
        let (idleness, said) = watched(jobs: 1)
        XCTAssertThrowsError(try idleness.waiting { throw Lost() })
        XCTAssertEqual(said.withLock { $0 }, [true, false])
    }

    func testTheBoardCountsABegunWaitUntilItEnds() {
        let board = StageBoard()
        board.set(.elevation, .done)
        board.set(.split, .running, "reading the extract")
        board.beginWaiting(.split)
        let stage = board.stages.first { $0.id == .split }!
        XCTAssertTrue(stage.isHeld(among: board.stages))
        XCTAssertEqual(stage.shown(among: board.stages).status, .pending)
        board.endWaiting(.split)
        XCTAssertFalse(board.stages.first { $0.id == .split }!.isWaiting)
    }
}
