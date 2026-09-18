import XCTest
@testable import kmap

/// What the elevation download reports while it runs: tiles done, bytes received, and,
/// once there is enough to go on, a rate and a time left.
final class StageElevationTests: XCTestCase {

    private func line(done: Int = 0, of total: Int = 100, received: Int64 = 0,
                      elapsed: TimeInterval = 10, secondsLeft: Double? = nil) -> String {
        BuildPipeline.fetchLine(done: done, of: total, received: received,
                                elapsed: elapsed, secondsLeft: secondsLeft)
    }

    func testItAlwaysSaysHowManyTilesAndHowMuchHasComeDown() {
        XCTAssertEqual(line(done: 20, of: 125, received: 0, elapsed: 0), "Copernicus 20/125 · 0 B")
        XCTAssertTrue(line(done: 20, of: 125, received: 240_000_000)
                        .hasPrefix("Copernicus 20/125 · 240.0 MB"))
    }

    func testNothingIsSaidAboutSpeedForTheFirstSecond() {
        // The first tiles are still opening connections; a rate taken there swings wildly.
        let early = line(done: 1, received: 5_000_000, elapsed: 0.4, secondsLeft: 90)
        XCTAssertFalse(early.contains("/s"), early)
        XCTAssertFalse(early.contains("left"), early)
    }

    func testTheRateIsWhatHasActuallyComeDownOverTheTimeItTook() {
        let text = line(done: 10, received: 100_000_000, elapsed: 10)
        XCTAssertTrue(text.contains("10.0 MB/s"), text)
    }

    func testTheTimeLeftIsWhateverThePaceWorkedOut() {
        // `Pace` supplies the estimate, from how fast tiles have been finishing lately.
        XCTAssertTrue(line(done: 10, of: 100, received: 100_000_000, elapsed: 10,
                           secondsLeft: 90).contains("1m 30s left"))
    }

    func testNothingIsSaidAboutTimeWhileThePaceIsStillWatching() {
        let text = line(done: 3, received: 30_000_000, elapsed: 5, secondsLeft: nil)
        XCTAssertTrue(text.contains("MB/s"), text)
        XCTAssertFalse(text.contains("left"), text)
    }

    func testAnEmptyFetchDoesNotDivideByZero() {
        XCTAssertFalse(line(done: 0, of: 0, received: 0, elapsed: 30).isEmpty)
        XCTAssertFalse(line(done: 0, of: 0, received: 1_000, elapsed: 30).isEmpty)
    }
}

/// Adding up what several lanes are pulling down at once.
final class FlightTests: XCTestCase {

    func testItStartsAtNothing() {
        XCTAssertEqual(Flight().received, 0)
    }

    func testAFinishedLanesBytesAreCountedOnce() {
        let flight = Flight()
        let a = Downloader(log: Log())
        flight.joined(a)
        flight.left(a, carrying: 12_000_000)
        XCTAssertEqual(flight.received, 12_000_000)
        // And the downloader is let go rather than kept and re-counted.
        XCTAssertEqual(flight.received, 12_000_000)
    }

    func testALaneThatFoundNothingAddsNothing() {
        // A degree cell of open sea is not in the bucket, which is not a failure.
        let flight = Flight()
        let a = Downloader(log: Log())
        flight.joined(a)
        flight.left(a, carrying: 0)
        XCTAssertEqual(flight.received, 0)
    }

    func testEveryLaneCountsAndTheTotalNeverGoesBackwards() {
        let flight = Flight()
        var last: Int64 = 0
        var live: [Downloader] = []
        for _ in 0..<6 {
            let d = Downloader(log: Log())
            live.append(d)
            flight.joined(d)
            XCTAssertGreaterThanOrEqual(flight.received, last)
            last = flight.received
        }
        for (index, d) in live.enumerated() {
            flight.left(d, carrying: 1_000_000)
            XCTAssertEqual(flight.received, Int64(index + 1) * 1_000_000)
        }
    }

    func testLanesJoinAndLeaveFromEveryThreadAtOnce() {
        // Lanes join and leave on many threads while the total is read.
        let flight = Flight()
        DispatchQueue.concurrentPerform(iterations: 8) { _ in
            for _ in 0..<200 {
                let d = Downloader(log: Log())
                flight.joined(d)
                _ = flight.received
                flight.left(d, carrying: 1_000)
            }
        }
        XCTAssertEqual(flight.received, 8 * 200 * 1_000)
    }
}
