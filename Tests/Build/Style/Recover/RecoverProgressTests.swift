import XCTest
@testable import kmap

/// What a recovery reports while it runs: a count where no total exists, a bar where one
/// does, written from many cores and read by the render loop.
final class RecoverProgressTests: XCTestCase {

    func testItStartsPreparingWithNothingToShow() {
        let snapshot = RecoverProgress().snapshot
        XCTAssertEqual(snapshot.stage, .preparing)
        XCTAssertEqual(snapshot.done, 0)
        XCTAssertNil(snapshot.fraction)
    }

    func testReadingShowsACountAndNeverABar() {
        // The map's element count is unknown until the last tile is read.
        let progress = RecoverProgress()
        progress.move(to: .reading)
        progress.count(120_000, of: 500_000)
        XCTAssertEqual(progress.snapshot.done, 120_000)
        XCTAssertNil(progress.snapshot.fraction)
    }

    func testMatchingAndPlacingHaveATrueTotal() {
        let progress = RecoverProgress()
        for stage in [RecoverProgress.Stage.matching("crimea"), .placing("crimea")] {
            progress.move(to: stage)
            XCTAssertNil(progress.snapshot.fraction, "no total yet")
            progress.count(0, of: 200)
            progress.advance(50)
            XCTAssertEqual(progress.snapshot.fraction ?? 0, 0.25, accuracy: 1e-9)
        }
    }

    func testMovingOnForgetsTheLastStagesNumbers() {
        let progress = RecoverProgress()
        progress.move(to: .matching("a"))
        progress.count(10, of: 20)
        progress.move(to: .indexing("b"))
        XCTAssertEqual(progress.snapshot.done, 0)
        XCTAssertEqual(progress.snapshot.total, 0)
        XCTAssertEqual(progress.snapshot.stage, .indexing("b"))
    }

    func testACountWithoutATotalKeepsTheOneAlreadyKnown() {
        let progress = RecoverProgress()
        progress.move(to: .matching("a"))
        progress.count(5, of: 40)
        progress.count(9)
        XCTAssertEqual(progress.snapshot.total, 40)
        XCTAssertEqual(progress.snapshot.done, 9)
    }

    func testEveryCoreCountsIntoTheSameNumber() {
        let progress = RecoverProgress()
        progress.move(to: .matching("a"))
        progress.count(0, of: 8000)
        DispatchQueue.concurrentPerform(iterations: 8) { _ in
            for _ in 0..<1000 { progress.advance(1) }
        }
        XCTAssertEqual(progress.snapshot.done, 8000)
        XCTAssertEqual(progress.snapshot.fraction ?? 0, 1, accuracy: 1e-9)
    }
}
