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
        /// The furthest `overall` has already reached this run. A running stage without
        /// a fraction is guessed at a third done, so the raw figure can dip when the
        /// first real fraction arrives; the bar must not.
        var overallFloor: Double = 0

        var overall: Double { max(rawOverall, overallFloor) }

        var rawOverall: Double {
            let weights: [StageID: Double] = [
                // Weights per stage; elevation is split in two because fetching a degree
                // cell costs far more than tracing it.
                .preflight: 0.01, .dataUpdate: 0.01, .download: 0.23, .elevation: 0.20,
                .elevationBuild: 0.10, .split: 0.15, .compile: 0.28, .collect: 0.02
            ]
            var total = 0.0
            for stage in stages {
                let w = weights[stage.id] ?? 0
                switch stage.status {
                case .done, .skipped: total += w
                case .running: total += w * (stage.fraction ?? 0.35)
                default: break
                }
            }
            return min(1, total)
        }
    }
}
