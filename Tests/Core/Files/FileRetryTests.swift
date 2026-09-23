import XCTest

@testable import kmap

/// The retry behind the file operations Windows can refuse while another process holds
/// the file: tried again through the pauses, and the last error thrown as it came.
final class FileRetryTests: XCTestCase {
    private struct Held: Error, Equatable { let attempt: Int }
    private struct Refused: Error {}

    /// Runs the retry against a body that fails `failures` times, then succeeds.
    private func run(
        failing failures: Int,
        with error: (Int) -> Error = { Held(attempt: $0) },
        transient: @escaping (Error) -> Bool = { $0 is Held }
    ) -> (result: Result<Int, Error>, attempts: Int, pauses: [UInt32]) {
        var attempts = 0
        var pauses: [UInt32] = []
        let result = Result {
            try FileRetry.attempt(isTransient: transient, pause: { pauses.append($0) }) { () -> Int in
                attempts += 1
                if attempts <= failures { throw error(attempts) }
                return attempts
            }
        }
        return (result, attempts, pauses)
    }

    func testAHeldFileIsTriedAgainUntilItGoesThrough() throws {
        let made = run(failing: 3)
        XCTAssertEqual(try made.result.get(), 4)
        XCTAssertEqual(made.attempts, 4)
        XCTAssertEqual(made.pauses, Array(FileRetry.pausesMilliseconds.prefix(3)))
    }

    func testAFirstTimeSuccessPausesNowhere() throws {
        let made = run(failing: 0)
        XCTAssertEqual(try made.result.get(), 1)
        XCTAssertEqual(made.pauses, [])
    }

    func testThePausesRunOutAndTheLastErrorIsThrownAsItCame() {
        let count = FileRetry.pausesMilliseconds.count
        let made = run(failing: count + 5)
        XCTAssertEqual(made.attempts, count + 1, "one attempt per pause, and the first")
        XCTAssertEqual(made.pauses, FileRetry.pausesMilliseconds)
        guard case .failure(let error) = made.result else { return XCTFail("succeeded") }
        XCTAssertEqual(error as? Held, Held(attempt: count + 1), "the last attempt's own error")
    }

    func testAnErrorThatIsNotTransientIsNotTriedAgain() {
        let made = run(failing: 1, with: { _ in Refused() })
        XCTAssertEqual(made.attempts, 1)
        XCTAssertEqual(made.pauses, [])
        guard case .failure(let error) = made.result else { return XCTFail("succeeded") }
        XCTAssertTrue(error is Refused)
    }

    /// The pauses add up to about a second: long enough for a scanner, short enough that a
    /// file that is really held does not stall the interface.
    func testThePausesAddUpToAboutASecond() {
        let total = FileRetry.pausesMilliseconds.reduce(0, +)
        XCTAssertGreaterThanOrEqual(total, 1000)
        XCTAssertLessThan(total, 2000)
        XCTAssertEqual(FileRetry.pausesMilliseconds, FileRetry.pausesMilliseconds.sorted(), "growing")
    }
}
