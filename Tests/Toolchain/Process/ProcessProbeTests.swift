import XCTest

@testable import kmap

/// The version probes the toolchain screen and `doctor` run.
final class ProcessProbeTests: XCTestCase {
    func testCaptureReturnsWhatTheToolPrinted() {
        let echo = TestShell.echo("mkgmap 4917")
        let out = ProcessProbe.capture(echo.executable, echo.arguments)
        XCTAssertEqual(out?.trimmingCharacters(in: .whitespacesAndNewlines), "mkgmap 4917")
    }

    func testCaptureAnswersNothingForSomethingThatIsNotAToolAtAll() {
        // The toolchain screen probes candidate paths; each miss must be quiet.
        XCTAssertNil(ProcessProbe.capture(TestShell.nowhere, ["-version"]))
        XCTAssertNil(ProcessProbe.capture(NSTemporaryDirectory(), ["-version"]))
    }

    func testOutputLeavesTheErrorStreamOut() {
        let out = ProcessProbe.output(TestShell.path, TestShell.arguments(.toBothStreams))
        XCTAssertEqual(out?.trimmingCharacters(in: .whitespacesAndNewlines), "out")
    }

    func testOutputIsNothingWhereTheToolFailed() {
        // A failing tool's complaint is not its answer, whichever stream it uses.
        XCTAssertNil(ProcessProbe.output(TestShell.path, TestShell.arguments(.failWithReason)))
        XCTAssertNil(ProcessProbe.output(TestShell.path, TestShell.arguments(.exitSeven)))
    }

    func testCaptureGivesUpOnSomethingThatNeverFinishes() {
        // The toolchain screen probes candidate paths this way, and a probe that never
        // returns freezes the interface behind it.
        let started = Date()
        _ = ProcessProbe.capture(TestShell.path, TestShell.arguments(.sleep), timeout: 1)
        XCTAssertLessThan(Date().timeIntervalSince(started), 10)
    }
}
