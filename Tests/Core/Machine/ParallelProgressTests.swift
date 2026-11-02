import XCTest

@testable import kmap

/// Pieces of work side by side, each telling its own progress.
final class ParallelProgressTests: XCTestCase {
    private func listening() -> (ProgressReport, Locked<[Double]>) {
        let told = Locked<[Double]>([])
        return (ProgressReport { at in told.withLock { $0.append(at) } }, told)
    }

    func testPiecesTakenInTurnAddUpByWeight() {
        let (report, told) = listening()
        let progress = ParallelProgress(weights: [3, 1], into: report)
        progress.piece(1)(1)
        progress.piece(0)(0.5)
        XCTAssertEqual(told.withLock { $0 }, [0.25, 0.25 + 0.375])
    }

    func testPiecesThatEndTogetherAreAsFarAsTheOneBehind() {
        let (report, told) = listening()
        let progress = ParallelProgress(slowestOf: 3, into: report)
        progress.piece(0)(1)
        progress.piece(1)(0.8)
        progress.piece(2)(0.3)
        XCTAssertEqual(told.withLock { $0 }, [0, 0, 0.3])
    }

    func testAPieceNeverReportsItselfBackwards() {
        // A piece that starts a second read from 0 does not undo the first.
        let (report, told) = listening()
        let progress = ParallelProgress(weights: [1], into: report)
        progress.piece(0)(0.6)
        progress.piece(0)(0.1)
        XCTAssertEqual(told.withLock { $0 }, [0.6, 0.6])
    }
}
