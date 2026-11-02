import Foundation

/// A bar of parts in order, each as wide as its weight.
struct ProgressCourse<Part: Hashable & Sendable>: Sendable {
    private let starts: [Part: Double]
    private let widths: [Part: Double]

    init(_ parts: [(part: Part, weight: Double)]) {
        let total = parts.reduce(0) { $0 + max(0, $1.weight) }
        var starts: [Part: Double] = [:]
        var widths: [Part: Double] = [:]
        var start = 0.0
        for (part, weight) in parts {
            let width = total > 0 ? max(0, weight) / total : 0
            starts[part] = start
            widths[part] = width
            start += width
        }
        self.starts = starts
        self.widths = widths
    }

    /// 0 for an unknown part.
    func position(_ part: Part, at fraction: Double = 0) -> Double {
        guard let start = starts[part], let width = widths[part] else { return 0 }
        return start + width * min(1, max(0, fraction))
    }
}

extension ProgressCourse where Part == Int {
    init(weights: [Double]) {
        self.init(weights.enumerated().map { (part: $0.offset, weight: $0.element) })
    }
}
