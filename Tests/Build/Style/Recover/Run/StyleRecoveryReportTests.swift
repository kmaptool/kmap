import XCTest

@testable import kmap

/// What a report says of the codes an earlier run left unsettled.
final class StyleRecoveryReportTests: XCTestCase {
    /// What a run settled of the codes left before it: those it found a meaning for. A
    /// code settled before, or met only now, is no gain of the region read for them.
    func testSettledCodesAreThoseLeftBeforeWithAMeaningNow() {
        var report = StyleRecovery.Report()
        let statuses: [StyleRecovery.Status] = [.resolved, .noRule, .mixed, .singleWitness, .noEvidence, .resolved]
        for (at, status) in statuses.enumerated() {
            report.outcomes["L\(at)"] = StyleRecovery.Outcome(
                kind: .line,
                type: at,
                witnesses: 1,
                elements: 1,
                unmatched: 0,
                ambiguous: 0,
                meaning: "",
                status: status
            )
        }
        var before = StyleRecovery.Remainder()
        for type in 0..<5 { before.seen[Evidence.slot(.line, type)] = StyleRecovery.Remainder.Sighting() }
        XCTAssertEqual(report.settled(of: before), 2)
        XCTAssertEqual(report.settled(of: StyleRecovery.Remainder()), 0)
    }
}
