import XCTest
@testable import kmap

/// The progress a download is watched through. Several connections write into their own
/// ranges of one file, and the counters are read from the render loop while the network
/// writes them.
final class DownloadProgressTests: XCTestCase {


    func testNothingIsKnownBeforeTheSizeIs() {
        // The screen reads these before the first response arrives.
        let progress = DownloadProgress()
        XCTAssertEqual(progress.total, 0)
        XCTAssertEqual(progress.received, 0)
        XCTAssertEqual(progress.fraction, 0)
        XCTAssertEqual(progress.rate, 0)
        XCTAssertEqual(progress.eta, .infinity)
        XCTAssertTrue(progress.partFractions.isEmpty)
        XCTAssertFalse(progress.stage.isEmpty)
    }

    func testEachConnectionCountsIntoTheWholeAndIntoItsOwnBar() {
        let progress = DownloadProgress()
        progress.begin(total: 1000, partTotals: [400, 600], alreadyOnDisk: 0)
        progress.advance(part: 0, by: 200)
        progress.advance(part: 1, by: 300)
        XCTAssertEqual(progress.received, 500)
        XCTAssertEqual(progress.fraction, 0.5)
        XCTAssertEqual(progress.partFractions, [0.5, 0.5])
    }

    func testAPartOutsideTheRangeIsIgnoredRatherThanCrashing() {
        // The delegate is called back per task, and a cancelled download can still deliver.
        let progress = DownloadProgress()
        progress.begin(total: 100, partTotals: [100], alreadyOnDisk: 0)
        progress.advance(part: 7, by: 50)
        progress.seedPart(7, bytes: 50)
        XCTAssertEqual(progress.received, 0)
    }

    func testWhatIsAlreadyOnDiskCountsAsReceivedButNotAsSpeed() {
        // Otherwise a resumed download reports an impossible rate for its first moment.
        let progress = DownloadProgress()
        progress.begin(total: 1000, partTotals: [1000], alreadyOnDisk: 900)
        XCTAssertEqual(progress.received, 900)
        XCTAssertEqual(progress.fraction, 0.9)
        XCTAssertEqual(progress.rate, 0)
    }

    func testTheRateIsNotGuessedAtFromTheFirstInstant() {
        // The rate takes half a second of samples before it says anything.
        let progress = DownloadProgress()
        progress.begin(total: 1_000_000, partTotals: [1_000_000], alreadyOnDisk: 0)
        progress.advance(part: 0, by: 100_000)
        XCTAssertEqual(progress.rate, 0)
        XCTAssertEqual(progress.eta, .infinity)
    }

    func testTheCountersHoldUpUnderEveryConnectionAtOnce() {
        let progress = DownloadProgress()
        let parts = 8
        progress.begin(total: Int64(parts * 1000),
                       partTotals: Array(repeating: 1000, count: parts), alreadyOnDisk: 0)
        DispatchQueue.concurrentPerform(iterations: parts) { part in
            for _ in 0..<1000 { progress.advance(part: part, by: 1) }
        }
        XCTAssertEqual(progress.received, Int64(parts * 1000))
        XCTAssertEqual(progress.fraction, 1)
        XCTAssertEqual(progress.partFractions, Array(repeating: 1, count: parts))
    }

    func testStartingAgainForgetsTheLastDownload() {
        let progress = DownloadProgress()
        progress.begin(total: 100, partTotals: [100], alreadyOnDisk: 0)
        progress.advance(part: 0, by: 100)
        progress.begin(total: 500, partTotals: [200, 300], alreadyOnDisk: 0)
        XCTAssertEqual(progress.received, 0)
        XCTAssertEqual(progress.total, 500)
        XCTAssertEqual(progress.partFractions, [0, 0])
    }
}
