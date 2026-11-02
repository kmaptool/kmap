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

        var overall: Double { max(rawOverall, overallFloor) }

        /// Shares of a build's time, from measured builds.
        static let weights: [StageID: Double] = [
            .preflight: 0.01, .dataUpdate: 0.01, .download: 0.23, .elevation: 0.20,
            .elevationBuild: 0.03, .split: 0.20, .compile: 0.30, .collect: 0.02
        ]

        /// A skipped stage has no share.
        var rawOverall: Double {
            var done = 0.0
            var whole = 0.0
            for stage in stages where stage.status != .skipped {
                let weight = Self.weights[stage.id] ?? 0
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
