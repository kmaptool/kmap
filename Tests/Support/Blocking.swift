import Foundation

@testable import kmap

/// Runs `body` to its end on the cooperative pool while the test's own thread waits on a
/// semaphore, and hands back what it returned or threw.
///
/// For a test that awaits something quick. XCTest on Linux runs an `async` test as a task
/// and parks the main thread until the task says it is done, and a task that finishes
/// before the thread has parked loses that wake-up: the process sleeps with its test
/// passed. A semaphore counts its signals, so waiting on one has no such window.
func blocking<T: Sendable>(_ body: @escaping @Sendable () async throws -> T) throws -> T {
    let done = DispatchSemaphore(value: 0)
    let outcome = Locked<Result<T, Error>?>(nil)
    Task.detached {
        let result: Result<T, Error>
        do {
            result = .success(try await body())
        } catch {
            result = .failure(error)
        }
        outcome.withLock { $0 = result }
        done.signal()
    }
    done.wait()
    // The task stores its outcome before it signals, so it is there.
    return try outcome.withLock { $0 }!.get()
}
