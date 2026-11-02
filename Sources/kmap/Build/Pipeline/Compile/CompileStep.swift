import Foundation

extension BuildPipeline {
    /// Seconds on Germany.
    enum CompileStep: Sendable {
        case tiles, overview, files

        static let course = ProgressCourse<CompileStep>([(.tiles, 454.7), (.overview, 6.5), (.files, 37.2)])
    }
}
