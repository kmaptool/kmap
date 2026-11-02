import Foundation

extension BuildPipeline {
    struct Output {
        let name: String
        let url: URL
        let size: Int64
    }

    struct Snapshot {
        var stages: [Stage]
        var finished: Bool
        var failure: String?
        var cancelled: Bool
        var outputs: [Output]
        var startedAt: Date
        var finishedAt: Date?
        /// So a re-split does not take the bar back.
        var overallFloor: Double = 0
        var weights = StageWeights.measured

        var overall: Double { max(rawOverall, overallFloor) }

        /// A skipped stage has no share.
        var rawOverall: Double {
            var done = 0.0
            var whole = 0.0
            for stage in stages where stage.status != .skipped {
                let weight = weights[stage.id]
                whole += weight
                switch stage.status {
                case .done: done += weight
                case .running: done += weight * (stage.fraction ?? 0)
                case .pending, .skipped, .failed: break
                }
            }
            return whole > 0 ? min(1, done / whole) : 0
        }
    }
}
