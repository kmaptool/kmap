import Foundation

extension TileSplitter {
    /// Weighted by seconds on Germany.
    enum PlanStep: Hashable, Sendable {
        case sweep, refs, rings, fill, spread, place

        static let course = ProgressCourse<PlanStep>([
            (.sweep, 8.7), (.refs, 7.6), (.rings, 1.4), (.fill, 1.3), (.spread, 12.2), (.place, 1.5)
        ])
    }
}
