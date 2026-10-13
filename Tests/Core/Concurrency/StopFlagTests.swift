import XCTest

@testable import kmap

/// A task's cancellation carried to threads that cannot see it.
final class StopFlagTests: XCTestCase {
    func testTheFlagStaysDownUntilRaised() {
        let flag = StopFlag()
        XCTAssertFalse(flag.isRaised)
        flag.raise()
        XCTAssertTrue(flag.isRaised)
    }

    /// Raised from the task's cancellation, it is seen on a GCD thread.
    func testACancelledTaskRaisesItForTheGCDThreads() async {
        let flag = StopFlag()
        let task = Task {
            await withTaskCancellationHandler {
                while !flag.isRaised { await Task.yield() }
            } onCancel: {
                flag.raise()
            }
        }
        task.cancel()
        await task.value
        let seen = Locked(false)
        DispatchQueue.concurrentPerform(iterations: 2) { _ in seen.withLock { $0 = $0 || flag.isRaised } }
        XCTAssertTrue(seen.withLock { $0 })
    }
}
