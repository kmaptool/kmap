import Foundation

extension TileSplitter {
    enum PlaceStep: Hashable, Sendable {
        case count, assign

        static func course(counting: Bool) -> ProgressCourse<PlaceStep> {
            ProgressCourse([(.count, counting ? 1 : 0), (.assign, 1)])
        }
    }
}
