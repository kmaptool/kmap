import Foundation

extension BuildPipeline {
    /// A card file's parts, in seconds on Germany.
    enum OutputStep: Sendable {
        case takeIn, index, write

        static func course(indexing: Bool) -> ProgressCourse<OutputStep> {
            ProgressCourse([(.takeIn, 6.3), (.index, indexing ? 10.5 : 0), (.write, 10.9)])
        }
    }
}
