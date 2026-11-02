import Foundation

extension TileSplitter {
    /// Weighted by seconds on Germany.
    enum WriteStep: Hashable, Sendable {
        case nodes, ways, finish

        static let course = ProgressCourse<WriteStep>([(.nodes, 20.7), (.ways, 17.3), (.finish, 1.2)])
    }
}
