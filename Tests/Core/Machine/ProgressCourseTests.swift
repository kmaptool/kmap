import XCTest

@testable import kmap

/// A bar laid out as parts, each as wide as its weight.
final class ProgressCourseTests: XCTestCase {
    private enum Step: Hashable { case read, plan, write }

    func testEachPartTakesTheRoomItsWeightGivesIt() {
        let course = ProgressCourse<Step>([(.read, 1), (.plan, 1), (.write, 2)])
        XCTAssertEqual(course.position(.read), 0)
        XCTAssertEqual(course.position(.read, at: 1), 0.25, accuracy: 1e-9)
        XCTAssertEqual(course.position(.plan, at: 0.5), 0.375, accuracy: 1e-9)
        XCTAssertEqual(course.position(.write, at: 1), 1, accuracy: 1e-9)
    }

    func testAPartWithNoWorkTakesNoRoom() {
        // Nothing to read: the plan starts the bar.
        let course = ProgressCourse<Step>([(.read, 0), (.plan, 1), (.write, 1)])
        XCTAssertEqual(course.position(.read, at: 1), 0)
        XCTAssertEqual(course.position(.plan), 0)
        XCTAssertEqual(course.position(.write), 0.5, accuracy: 1e-9)
    }

    func testAPartsOwnProgressStaysInsideItsRoom() {
        let course = ProgressCourse(weights: [3, 1])
        XCTAssertEqual(course.position(0, at: -1), 0)
        XCTAssertEqual(course.position(0, at: 4), 0.75, accuracy: 1e-9)
        XCTAssertEqual(course.position(1, at: 4), 1, accuracy: 1e-9)
    }

    func testWithNoWeightAtAllNothingMoves() {
        let course = ProgressCourse(weights: [0, 0])
        XCTAssertEqual(course.position(1, at: 1), 0)
    }

    func testAPartsReportHandsOnThePositionOnTheWholeBar() {
        let course = ProgressCourse(weights: [1, 1])
        let heard = Locked<[Double]>([])
        let report = ProgressReport { at in heard.withLock { $0.append(at) } }.part(1, of: course)
        report(0)
        report(0.5)
        XCTAssertEqual(heard.withLock { $0 }, [0.5, 0.75])
    }

    func testPartsNestInsideOneAnother() {
        let outer = ProgressCourse<Step>([(.read, 1), (.plan, 1)])
        let inner = ProgressCourse(weights: [1, 3])
        let heard = Locked<[Double]>([])
        let report = ProgressReport { at in heard.withLock { $0.append(at) } }
        report.part(.plan, of: outer).part(1, of: inner)(0.5)
        XCTAssertEqual(heard.withLock { $0 }, [0.5 + 0.5 * (0.25 + 0.75 * 0.5)])
    }
}
