import XCTest

@testable import kmap

final class OutputStepTests: XCTestCase {
    /// With no search index the writing follows the take-in at once.
    func testACardFileWithNoIndexHasNoIndexPart() {
        let course = BuildPipeline.OutputStep.course(indexing: false)
        XCTAssertEqual(course.position(.takeIn, at: 1), course.position(.write), accuracy: 1e-12)
        let indexed = BuildPipeline.OutputStep.course(indexing: true)
        XCTAssertLessThan(indexed.position(.takeIn, at: 1), indexed.position(.write))
    }
}
