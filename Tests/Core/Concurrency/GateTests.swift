import XCTest

@testable import kmap

/// The road repair waits on the elevation tiles through a gate: it must be woken once
/// they are there, and never twice with different answers.
final class GateTests: XCTestCase {
    func testAWaiterIsWokenWithTheValueAndALateAskerHasItAtOnce() async {
        let gate = Gate<Int>()
        let waiting = Task { await gate.value }
        try? await Task.sleep(nanoseconds: 50_000_000)
        gate.open(7)
        let woken = await waiting.value
        XCTAssertEqual(woken, 7)
        let late = await gate.value
        XCTAssertEqual(late, 7)
    }

    func testAGateSaysWhetherAskingWouldWait() {
        let gate = Gate<Int>()
        XCTAssertFalse(gate.isOpen)
        XCTAssertNil(gate.opened)
        gate.open(3)
        XCTAssertTrue(gate.isOpen)
        XCTAssertEqual(gate.opened, 3)
    }

    func testOnlyTheFirstOpenCounts() async {
        let gate = Gate<Int>()
        gate.open(1)
        gate.open(2)
        let value = await gate.value
        XCTAssertEqual(value, 1)
    }

    func testManyWaitersAllWake() async {
        let gate = Gate<String>()
        let waiters = (0..<20).map { _ in Task { await gate.value } }
        gate.open("tiles")
        for waiter in waiters {
            let value = await waiter.value
            XCTAssertEqual(value, "tiles")
        }
    }
}
