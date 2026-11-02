import Foundation

extension BuildPipeline {
    enum SplitStep: Hashable, Sendable {
        case annotate, cut

        /// Seconds on Germany.
        static func course(annotating: Double) -> ProgressCourse<SplitStep> {
            ProgressCourse([(.annotate, annotating), (.cut, 78.7)])
        }
    }
}
