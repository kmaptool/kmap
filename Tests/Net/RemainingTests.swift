import XCTest
@testable import kmap

/// Covers the estimate of how much longer a transfer has to run, and its monotonicity
/// under a steady arrival rate.
final class RemainingTests: XCTestCase {

    // MARK: The shared arithmetic

    func testNothingIsClaimedBeforeThereIsASampleToClaimItFrom() {
        XCTAssertNil(Remaining.seconds(received: 5_000_000, total: 100_000_000, elapsed: 0.4))
        XCTAssertNil(Remaining.seconds(received: 0, total: 100_000_000, elapsed: 30))
    }

    func testTheAnswerIsWhatIsLeftOverHowFastItIsArriving() {
        // 10 MB of 100 MB in 10 s: 90 MB left at 1 MB/s.
        XCTAssertEqual(Remaining.seconds(received: 10_000_000, total: 100_000_000, elapsed: 10) ?? 0,
                       90, accuracy: 1e-6)
    }

    func testAFinishedTransferHasNoTimeLeftRatherThanZeroOrNonsense() {
        XCTAssertNil(Remaining.seconds(received: 100_000_000, total: 100_000_000, elapsed: 10))
        // A transfer past its stated size does not answer with a negative.
        XCTAssertNil(Remaining.seconds(received: 110_000_000, total: 100_000_000, elapsed: 10))
    }

    func testResumedBytesCountTowardsTheWorkButNotTowardsTheSpeed() {
        // 900 MB already on disk, 100 MB in 10 s: 10 MB/s, and nothing left.
        let resumed = Remaining.seconds(received: 1_000_000_000, total: 1_000_000_000,
                                        elapsed: 10, alreadyOnDisk: 900_000_000)
        XCTAssertNil(resumed)
        // Half way: 500 MB left, 100 MB fetched in 10 s, so 50 s.
        XCTAssertEqual(Remaining.seconds(received: 500_000_000, total: 1_000_000_000,
                                         elapsed: 10, alreadyOnDisk: 400_000_000) ?? 0,
                       50, accuracy: 1e-6)
    }

    // MARK: Counting down rather than up

    func testASteadyStreamCountsDownEverySecond() {
        // One file of known size, arriving at a constant rate.
        let total: Int64 = 900_000_000
        let perSecond: Int64 = 9_000_000
        var last = Double.infinity
        for second in 2...99 {
            let received = perSecond * Int64(second)
            let now = try? XCTUnwrap(Remaining.seconds(received: received, total: total,
                                                       elapsed: Double(second)))
            let value = (now ?? nil) ?? 0
            XCTAssertLessThan(value, last + 1e-6, "at \(second) s it went up")
            last = value
        }
        XCTAssertLessThan(last, 2)
    }

    // MARK: Working out a total nobody stated
}
