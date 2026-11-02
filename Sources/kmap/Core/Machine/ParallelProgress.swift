import Foundation

/// Progress of parallel pieces, each reporting 0...1 from its own thread.
final class ParallelProgress: Sendable {
    private let weights: [Double]?
    private let positions: Locked<[Double]>
    private let report: ProgressReport

    /// The weighted sum, for pieces run a few at a time.
    init(weights: [Double], into report: ProgressReport) {
        let total = weights.reduce(0) { $0 + max(0, $1) }
        self.weights = weights.map { total > 0 ? max(0, $0) / total : 0 }
        positions = Locked([Double](repeating: 0, count: weights.count))
        self.report = report
    }

    /// The slowest, for pieces run together.
    init(slowestOf count: Int, into report: ProgressReport) {
        weights = nil
        positions = Locked([Double](repeating: 0, count: count))
        self.report = report
    }

    /// Only moves forward.
    func piece(_ index: Int) -> ProgressReport {
        ProgressReport { [self] at in
            let whole = positions.withLock { positions in
                positions[index] = max(positions[index], min(1, max(0, at)))
                guard let weights else { return positions.min() ?? 0 }
                return zip(weights, positions).reduce(0) { $0 + $1.0 * $1.1 }
            }
            report(whole)
        }
    }
}
