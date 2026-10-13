import XCTest

@testable import kmap

/// Reading the codes stops when asked, and leaves nothing half-read behind.
final class StyleDeriveReadingsTests: XCTestCase {
    private func evidence(witnesses: Int) -> Evidence {
        var code = Evidence.ForCode(kind: .line, type: 0x30)
        for id in 1...witnesses { code.sources[Int64(id)] = ["highway": "path"] }
        return Evidence(codes: ["L30": code])
    }

    func testARaisedStopThrowsRatherThanReturningAPartReading() throws {
        let rules = try MiniRuleBook.load()
        let stop = StopFlag()
        stop.raise()
        var report = StyleRecovery.Report()
        XCTAssertThrowsError(
            try StyleRecovery.readCodes(evidence(witnesses: 10000), into: &report, rules: rules, stop: stop)
        ) {
            XCTAssertTrue($0 is CancellationError)
        }
    }

    func testWithTheStopDownEveryCodeIsRead() throws {
        let rules = try MiniRuleBook.load()
        var report = StyleRecovery.Report()
        let read = try StyleRecovery.readCodes(evidence(witnesses: 10000), into: &report, rules: rules)
        XCTAssertEqual(read.first?.meant, 10000)
    }

    /// A raised stop is seen inside a code too, every 4096 witnesses: a code of millions
    /// does not run to its end first.
    func testARaisedStopEndsACodeBetweenItsWitnesses() throws {
        let stop = StopFlag()
        stop.raise()
        let code = try XCTUnwrap(evidence(witnesses: 10000).codes["L30"])
        let read = StyleRecovery.reading("L30", code, rules: try MiniRuleBook.load(), stop: stop)
        XCTAssertNil(read.reading)
        XCTAssertNil(read.outcome)
    }
}
