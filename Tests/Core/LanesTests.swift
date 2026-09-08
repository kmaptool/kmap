import XCTest
@testable import kmap

/// How many workers a machine runs at once when each of them holds something large.
final class LanesTests: XCTestCase {

    func testTheCoresDecideWhenThereIsRoomForAllOfThem() {
        // Half the memory is spendable: 24 GB over 0.7 apiece exceeds the ten asked for.
        XCTAssertEqual(Machine.lanes(10, holdingEach: 0.7, memoryGB: 48), 10)
    }

    func testTheMemoryDecidesWhenThereIsNot() {
        // Half of 8 GB over 0.7 apiece is five lanes.
        XCTAssertEqual(Machine.lanes(10, holdingEach: 0.7, memoryGB: 8), 5)
    }

    func testOneLaneIsTheFloorHoweverTightItIs() {
        XCTAssertEqual(Machine.lanes(10, holdingEach: 40, memoryGB: 4), 1)
        XCTAssertEqual(Machine.lanes(3, holdingEach: 1000, memoryGB: 1), 1)
    }

    func testAskingForOneNeverGivesMore() {
        XCTAssertEqual(Machine.lanes(1, holdingEach: 0.1, memoryGB: 256), 1)
    }

    func testSomethingThatHoldsNothingIsBoundedOnlyByTheAsking() {
        XCTAssertEqual(Machine.lanes(12, holdingEach: 0, memoryGB: 4), 12)
    }
}
