import XCTest

@testable import kmap

/// The shares the bar gives each stage.
final class PipelineStageWeightsTests: XCTestCase {
    private let weights = BuildPipeline.StageWeights.measured

    func testTheWeightsAddUpToAWholeBuild() {
        // Otherwise a finished build stops short of the end or claims to be past it.
        let whole = BuildPipeline.StageID.allCases.reduce(0) { $0 + weights[$1] }
        XCTAssertEqual(whole, 1, accuracy: 1e-9)
    }

    func testTheCompileOutweighsTheSplitAndTheDownloadTheCopy() {
        XCTAssertGreaterThan(weights[.compile], weights[.split])
        XCTAssertGreaterThan(weights[.download], weights[.collect])
    }

    func testAStageTheTableDoesNotNameHasNoShare() {
        XCTAssertEqual(BuildPipeline.StageWeights(shares: [:])[.compile], 0)
    }
}
