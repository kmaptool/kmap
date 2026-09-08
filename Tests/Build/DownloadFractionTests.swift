import XCTest
@testable import kmap

/// The download bar over a multi-region build: one stage, several files.
final class DownloadFractionTests: XCTestCase {

    func testEachRegionOwnsItsSliceOfTheBar() {
        // Three regions: the second's halfway point is half of the middle third.
        XCTAssertEqual(BuildPipeline.overallFraction(region: 0, of: 3, at: 0), 0)
        XCTAssertEqual(BuildPipeline.overallFraction(region: 0, of: 3, at: 1), 1.0 / 3, accuracy: 1e-9)
        XCTAssertEqual(BuildPipeline.overallFraction(region: 1, of: 3, at: 0.5), 0.5, accuracy: 1e-9)
        XCTAssertEqual(BuildPipeline.overallFraction(region: 2, of: 3, at: 1), 1, accuracy: 1e-9)
    }

    func testALaterRegionCanNeverSitBehindAnEarlierOne() {
        // `advance()` takes the max, so the scaled fractions must be non-decreasing
        // across regions as well as within one.
        var last = -1.0
        for region in 0..<3 {
            for step in stride(from: 0.0, through: 1.0, by: 0.25) {
                let f = BuildPipeline.overallFraction(region: region, of: 3, at: step)
                XCTAssertGreaterThanOrEqual(f, last)
                last = f
            }
        }
        XCTAssertEqual(last, 1)
    }

    func testASingleRegionKeepsThePlainBar() {
        XCTAssertEqual(BuildPipeline.overallFraction(region: 0, of: 1, at: 0.62), 0.62, accuracy: 1e-9)
    }

    func testAWildFractionIsClampedIntoItsSlice() {
        // A downloader that reports 1.2 for a moment must not leak into the next slice.
        XCTAssertEqual(BuildPipeline.overallFraction(region: 0, of: 2, at: 1.2), 0.5, accuracy: 1e-9)
        XCTAssertEqual(BuildPipeline.overallFraction(region: 1, of: 2, at: -0.1), 0.5, accuracy: 1e-9)
    }

    // MARK: A bar that has to be able to start again

    /// The bar advances only within one piece of work: clearing the fraction starts the
    /// next piece from its own beginning.
    func testANewPieceOfWorkStartsTheBarAgain() {
        var stage = BuildPipeline.Stage(id: .download)
        stage.status = .running
        stage.advance(to: 1)                       // the cached copy was verified
        XCTAssertEqual(stage.fraction, 1)

        stage.fraction = nil                       // what beginPhase does
        stage.advance(to: 0.01)                    // the fresh download starts
        XCTAssertEqual(stage.fraction ?? 1, 0.01, accuracy: 0.001,
                       "a new piece of work counts from its own beginning")
    }

    func testWithinOnePieceOfWorkItStillOnlyAdvances() {
        var stage = BuildPipeline.Stage(id: .download)
        stage.status = .running
        stage.advance(to: 0.5)
        stage.advance(to: 0.2)
        XCTAssertEqual(stage.fraction ?? 0, 0.5, accuracy: 0.001)
    }
}
