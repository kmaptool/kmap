import Foundation

extension TileSplitter {
    /// Weighted by seconds on Germany.
    enum Phase: Hashable, Sendable {
        case measure, place, plan, write

        static func course(measuring: Bool) -> ProgressCourse<Phase> {
            ProgressCourse([(.measure, measuring ? 1.8 : 0), (.place, 4.4), (.plan, 32.9), (.write, 39.7)])
        }
    }
}
