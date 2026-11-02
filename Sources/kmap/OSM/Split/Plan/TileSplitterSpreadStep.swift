import Foundation

extension TileSplitter {
    /// Weighted by seconds on Germany.
    enum SpreadStep: Hashable, Sendable {
        case lanes, absorb, settle

        static let course = ProgressCourse<SpreadStep>([(.lanes, 4.3), (.absorb, 1.0), (.settle, 7.1)])
    }
}
