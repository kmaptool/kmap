import XCTest

@testable import kmap

/// The ledger of which codes draw which meanings.
final class StyleRecoveryLookTests: XCTestCase {
    private func evidence(witnesses: Int) -> Evidence {
        var code = Evidence.ForCode(kind: .line, type: 0x30)
        for id in 1...witnesses { code.sources[Int64(id)] = ["highway": "path"] }
        return Evidence(codes: ["L30": code])
    }

    func testTheLedgerCountsEachMeaningPerCode() throws {
        var report = StyleRecovery.Report()
        try StyleRecovery.ledger(evidence(witnesses: 7), into: &report)
        XCTAssertEqual(report.codesByTag["highway=path"]?["L30"], 7)
    }

    func testARaisedStopThrowsRatherThanLeavingAPartLedger() {
        let stop = StopFlag()
        stop.raise()
        var report = StyleRecovery.Report()
        XCTAssertThrowsError(try StyleRecovery.ledger(evidence(witnesses: 10000), into: &report, stop: stop)) {
            XCTAssertTrue($0 is CancellationError)
        }
        XCTAssertTrue(report.codesByTag.isEmpty)
    }
}
