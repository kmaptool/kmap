import XCTest

@testable import kmap

/// When a recovery reads 1 more region: ground leaving much of the map out, and codes
/// resting on a single sighting.
final class StyleRecoveryWeakEvidenceTests: XCTestCase {
    private func report(share: Double, weak: Int, of total: Int) -> StyleRecovery.Report {
        var out = StyleRecovery.Report()
        out.share = share
        for at in 0..<total {
            out.outcomes["L\(at)"] = StyleRecovery.Outcome(
                kind: .line,
                type: at,
                witnesses: at < weak ? 1 : 5,
                elements: 5,
                unmatched: 0,
                ambiguous: 0,
                meaning: "highway=path",
                status: at < weak ? .singleWitness : .resolved
            )
        }
        return out
    }

    func testWeakEvidenceOnPartOfTheMapAsksForMore() {
        XCTAssertEqual(report(share: 0.5, weak: 4, of: 100).weakEvidence, 0.04, accuracy: 1e-9)
        XCTAssertTrue(report(share: 0.5, weak: 4, of: 100).wantsMoreGround)
    }

    /// Crimea read whole: rare objects are rare, more ground would not help.
    func testAMapReadWholeIsLeftAlone() {
        XCTAssertFalse(report(share: 0.97, weak: 15, of: 235).wantsMoreGround)
    }

    func testFirmEvidenceIsLeftAlone() {
        XCTAssertFalse(report(share: 0.5, weak: 2, of: 100).wantsMoreGround)
    }
}
