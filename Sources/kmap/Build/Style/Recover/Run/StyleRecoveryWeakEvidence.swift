import Foundation

extension StyleRecovery.Report {
    /// The share of their codes seen once or not at all on the ground read: what more
    /// ground would firm up.
    var weakEvidence: Double {
        guard !outcomes.isEmpty else { return 0 }
        let weak = outcomes.values.filter { $0.status == .singleWitness || $0.status == .noEvidence }.count
        return Double(weak) / Double(outcomes.count)
    }

    /// Whether 1 more region is worth reading: the ground leaves a good part of the map
    /// out, and enough of their codes rest on a single sighting. A map read whole is
    /// left alone however rare its objects are.
    var wantsMoreGround: Bool {
        share < StyleRecovery.wholeEnough && weakEvidence >= StyleRecovery.weakEnough
    }
}
