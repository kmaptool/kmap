import XCTest

@testable import kmap

/// Which regions the annotate pass runs over, and so which share the split's bar.
final class SplitAnnotateTests: XCTestCase {
    func testOnlyTheFirstRegionFoldsTheContoursIn() {
        let pipeline = PipelineFixture.pipeline(regions: 2) {
            $0.codePage = CodePage.utf8
            $0.contours = true
        }
        XCTAssertTrue(pipeline.annotates(region: 0))
        XCTAssertFalse(pipeline.annotates(region: 1), "nothing to do: no share of the bar")
    }

    func testAFeatureRunsThePassOverEveryRegion() {
        let pipeline = PipelineFixture.pipeline(regions: 2) {
            $0.codePage = CodePage.utf8
            $0.contours = false
            $0.descriptions = .street
        }
        XCTAssertTrue(pipeline.annotates(region: 1))
    }

    func testACodePageCleansEveryRegionsLabels() {
        let pipeline = PipelineFixture.pipeline(regions: 2) { $0.contours = false }
        XCTAssertTrue(pipeline.annotates(region: 1))
    }
}
