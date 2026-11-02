import Foundation

/// Where work reports progress, 0...1, from any thread.
struct ProgressReport: Sendable {
    static let silent = ProgressReport { _ in }

    private let sink: @Sendable (Double) -> Void

    init(_ sink: @escaping @Sendable (Double) -> Void) {
        self.sink = sink
    }

    func callAsFunction(_ fraction: Double) {
        sink(fraction)
    }

    /// Maps 0...1 into the span of `part`.
    func part<Part>(_ part: Part, of course: ProgressCourse<Part>) -> ProgressReport {
        let sink = sink
        return ProgressReport { sink(course.position(part, at: $0)) }
    }
}
