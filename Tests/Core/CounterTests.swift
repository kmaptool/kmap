import XCTest
@testable import kmap

/// The counter progress is kept in while workers run.
final class CounterTests: XCTestCase {

    func testItCountsEveryIncrementFromEveryCore() {
        let counter = Counter()
        DispatchQueue.concurrentPerform(iterations: 8) { _ in
            for _ in 0..<1000 { counter.increment() }
        }
        XCTAssertEqual(counter.value, 8000)
    }

    func testItStartsAtZero() {
        XCTAssertEqual(Counter().value, 0)
    }
}
