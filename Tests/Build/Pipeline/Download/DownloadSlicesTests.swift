import XCTest
@testable import kmap

/// The download bar over a multi-region build: one stage, several files.
final class DownloadSlicesTests: XCTestCase {

    func testEachRegionOwnsItsSliceOfTheBar() {
        // Three regions: the second's halfway point is half of the middle third.
        XCTAssertEqual(BuildPipeline.DownloadSlices.equal(3).fraction(region: 0, at: 0), 0)
        XCTAssertEqual(BuildPipeline.DownloadSlices.equal(3).fraction(region: 0, at: 1), 1.0 / 3, accuracy: 1e-9)
        XCTAssertEqual(BuildPipeline.DownloadSlices.equal(3).fraction(region: 1, at: 0.5), 0.5, accuracy: 1e-9)
        XCTAssertEqual(BuildPipeline.DownloadSlices.equal(3).fraction(region: 2, at: 1), 1, accuracy: 1e-9)
    }

    func testALaterRegionCanNeverSitBehindAnEarlierOne() {
        // `advance()` takes the max, so the scaled fractions must be non-decreasing
        // across regions as well as within one.
        var last = -1.0
        for region in 0..<3 {
            for step in stride(from: 0.0, through: 1.0, by: 0.25) {
                let f = BuildPipeline.DownloadSlices.equal(3).fraction(region: region, at: step)
                XCTAssertGreaterThanOrEqual(f, last)
                last = f
            }
        }
        XCTAssertEqual(last, 1)
    }

    func testASingleRegionKeepsThePlainBar() {
        XCTAssertEqual(BuildPipeline.DownloadSlices.equal(1).fraction(region: 0, at: 0.62), 0.62, accuracy: 1e-9)
    }

    func testAWildFractionIsClampedIntoItsSlice() {
        // A downloader that reports 1.2 for a moment must not leak into the next slice.
        XCTAssertEqual(BuildPipeline.DownloadSlices.equal(2).fraction(region: 0, at: 1.2), 0.5, accuracy: 1e-9)
        XCTAssertEqual(BuildPipeline.DownloadSlices.equal(2).fraction(region: 1, at: -0.1), 0.5, accuracy: 1e-9)
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

    // MARK: Across the regions of one build

    private func pipeline() -> BuildPipeline {
        let settings = SettingsStore()
        let toolchain = Toolchain(settings: settings)
        let region = Region(id: "continent/small-region", name: "Small Region",
                            parentID: nil, pbfURL: nil, bbox: .empty, boxes: [])
        let style = MapStyle(id: "plain", name: "Plain", summary: "", origin: .builtin,
                             styleDirectory: nil, typURL: nil, familyID: 6300, productID: 1)
        let recipe = BuildRecipe(region: region, style: style,
                                 outputDirectory: URL(fileURLWithPath: NSTemporaryDirectory()))
        return BuildPipeline(recipe: recipe, settings: settings, toolchain: toolchain,
                             styles: StyleCatalog(settings: settings, toolchain: toolchain))
    }

    private func downloadBar(_ build: BuildPipeline) -> Double? {
        build.snapshot().stages.first { $0.id == .download }?.fraction
    }

    /// What the stage does per region: announce it, report text-only phases, move the bar
    /// inside the region's slice. The bar has to survive all of it.
    func testTheBarDoesNotStartOverForTheNextRegion() {
        let build = pipeline()
        build.set(.download, .running, "starting")
        build.detail(.download, "1/3", fraction: BuildPipeline.DownloadSlices.equal(3).fraction(region: 0, at: 1))
        build.detail(.download, "1/3 verifying checksum")

        build.set(.download, .running, "starting")
        build.detail(.download, "verifying cached copy")
        XCTAssertEqual(downloadBar(build) ?? 0, 1.0 / 3, accuracy: 1e-9,
                       "the second region begins where the first ended")

        build.detail(.download, "2/3", fraction: BuildPipeline.DownloadSlices.equal(3).fraction(region: 1, at: 0.5))
        XCTAssertEqual(downloadBar(build) ?? 0, 0.5, accuracy: 1e-9)
    }

    /// Finishing the stage after the first region would credit the whole download to the
    /// build's bar, which then stands still through the rest of it.
    func testOneRegionOfThreeIsNotTheWholeDownload() {
        let build = pipeline()
        build.set(.download, .running, "starting")
        build.detail(.download, "1/3", fraction: BuildPipeline.DownloadSlices.equal(3).fraction(region: 0, at: 1))
        let afterOne = build.snapshot().overall
        build.detail(.download, "3/3", fraction: BuildPipeline.DownloadSlices.equal(3).fraction(region: 2, at: 1))
        XCTAssertGreaterThan(build.snapshot().overall, afterOne)
    }

    // MARK: Slices by size

    func testALargerRegionOwnsMoreOfTheBar() {
        // 40 MB, 130 MB and 310 MB: a twelfth, then a bit over a quarter, then the rest.
        let slices = BuildPipeline.DownloadSlices(sizes: [40, 130, 310])
        XCTAssertEqual(slices.fraction(region: 0, at: 1), 40.0 / 480, accuracy: 1e-9)
        XCTAssertEqual(slices.fraction(region: 1, at: 0), 40.0 / 480, accuracy: 1e-9)
        XCTAssertEqual(slices.fraction(region: 1, at: 1), 170.0 / 480, accuracy: 1e-9)
        XCTAssertEqual(slices.fraction(region: 2, at: 0.5), (170.0 + 155) / 480, accuracy: 1e-9)
        XCTAssertEqual(slices.fraction(region: 2, at: 1), 1, accuracy: 1e-9)
    }

    func testTheBarMovesAtThePaceOfTheBytes() {
        // Half of all the bytes is half of the bar, wherever the region boundaries fall.
        let slices = BuildPipeline.DownloadSlices(sizes: [100, 300])
        XCTAssertEqual(slices.fraction(region: 1, at: 1.0 / 3), 0.5, accuracy: 1e-9)
    }

    func testOneUnknownSizeMakesTheSlicesEqual() {
        // A server that did not answer and nothing cached: no honest proportion to draw.
        let slices = BuildPipeline.DownloadSlices(sizes: [40, 0, 310])
        XCTAssertEqual(slices.fraction(region: 0, at: 1), 1.0 / 3, accuracy: 1e-9)
        XCTAssertEqual(slices.fraction(region: 2, at: 0), 2.0 / 3, accuracy: 1e-9)
    }

    func testWeightedSlicesNeverMoveBackwards() {
        let slices = BuildPipeline.DownloadSlices(sizes: [7, 1, 900, 3])
        var last = 0.0
        for region in 0..<4 {
            for step in stride(from: 0.0, through: 1.0, by: 0.1) {
                let f = slices.fraction(region: region, at: step)
                XCTAssertGreaterThanOrEqual(f, last - 1e-12)
                last = f
            }
        }
        XCTAssertEqual(last, 1, accuracy: 1e-9)
    }

    func testARegionOutsideThePlanIsNotACrash() {
        XCTAssertEqual(BuildPipeline.DownloadSlices(sizes: [1, 2]).fraction(region: 5, at: 1), 0)
    }

    // MARK: The time left is the stage's

    func testTheTimeLeftCoversTheRegionsStillToCome() {
        // 43.7 MB of this file and 313.6 MB after it, at 2.6 MB/s: about 137 s, not 17.
        let left = BuildPipeline.stageSecondsLeft(fileSecondsLeft: 43.7 / 2.6, rate: 2.6e6,
                                                  bytesAfterThisFile: 313_600_000)
        XCTAssertEqual(left ?? 0, (43.7 + 313.6) / 2.6, accuracy: 0.01)
    }

    func testTheLastRegionsTimeLeftIsItsOwn() {
        XCTAssertEqual(BuildPipeline.stageSecondsLeft(fileSecondsLeft: 65, rate: 4e6,
                                                      bytesAfterThisFile: 0) ?? 0, 65, accuracy: 1e-9)
    }

    func testNothingIsSaidBeforeTheRateSettles() {
        XCTAssertNil(BuildPipeline.stageSecondsLeft(fileSecondsLeft: .infinity, rate: 0,
                                                    bytesAfterThisFile: 100))
        XCTAssertNil(BuildPipeline.stageSecondsLeft(fileSecondsLeft: 10, rate: 0,
                                                    bytesAfterThisFile: 100))
    }
}
