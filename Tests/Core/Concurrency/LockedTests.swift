import XCTest

@testable import kmap

/// A value behind a lock, shared by threads no actor can own.
final class LockedTests: XCTestCase {
    func testEveryThreadCountsIntoTheSameValue() {
        let counter = Locked(0)
        DispatchQueue.concurrentPerform(iterations: 16) { _ in
            for _ in 0..<1000 { counter.withLock { $0 += 1 } }
        }
        XCTAssertEqual(counter.withLock { $0 }, 16_000)
    }

    func testAChangeAndWhatItReturnsAreOneStep() {
        // Taking a value out and reading what is left must not be two trips to the lock.
        let queue = Locked(["a", "b", "c"])
        let (taken, left) = queue.withLock { ($0.removeFirst(), $0.count) }
        XCTAssertEqual(taken, "a")
        XCTAssertEqual(left, 2)
    }

    func testAThrowLeavesTheLockFree() {
        struct Refused: Error {}
        let value = Locked(1)
        XCTAssertThrowsError(try value.withLock { _ in throw Refused() })
        XCTAssertEqual(value.withLock { $0 }, 1, "a lock left held would hang here")
    }

    func testStructuredStateChangesAsAWhole() {
        struct State { var open: [Int: String] = [:]; var closed = false }
        let state = Locked(State())
        state.withLock { $0.open[7] = "seven" }
        let (had, closed) = state.withLock { state -> (String?, Bool) in
            state.closed = true
            return (state.open.removeValue(forKey: 7), state.closed)
        }
        XCTAssertEqual(had, "seven")
        XCTAssertTrue(closed)
        XCTAssertTrue(state.withLock { $0.open.isEmpty })
    }
}
