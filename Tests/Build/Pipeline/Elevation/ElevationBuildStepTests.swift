import XCTest

@testable import kmap

/// The bar of the contours and DEM stage.
final class ElevationBuildStepTests: XCTestCase {
    func testAPartWithNothingToDoTakesNoRoom() {
        // No contours and no DEM layer: the conversion is the whole bar.
        let pipeline = PipelineFixture.pipeline {
            $0.contours = false
            $0.demLayer = false
        }
        pipeline.elevationConversionBegins(4)
        let course = pipeline.elevationBuildCourse()
        XCTAssertEqual(course.position(.convert, at: 0.5), 0.5, accuracy: 1e-9)
        XCTAssertEqual(course.position(.water), 1, accuracy: 1e-9)
        XCTAssertEqual(course.position(.summits), 1, accuracy: 1e-9)
    }

    func testEachCellConvertedMovesTheStage() {
        let pipeline = PipelineFixture.pipeline {
            $0.contours = false
            $0.demLayer = false
        }
        pipeline.elevationConversionBegins(4)
        pipeline.set(.elevationBuild, .running)
        pipeline.elevationCellConverted()
        pipeline.elevationCellConverted()
        let stage = pipeline.board.stages.first { $0.id == .elevationBuild }
        XCTAssertEqual(stage?.fraction ?? 0, 0.5, accuracy: 1e-9)
        XCTAssertEqual(stage?.detail, "converting 2/4")
    }

    func testWithNothingConvertedTheBarHoldsNoRoomForIt() {
        let pipeline = PipelineFixture.pipeline {
            $0.contours = false
            $0.demLayer = false
        }
        XCTAssertEqual(pipeline.elevationBuildCourse().position(.convert, at: 1), 0)
    }
}
