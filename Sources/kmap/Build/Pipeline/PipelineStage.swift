import Foundation

extension BuildPipeline {
    enum StageStatus: String {
        case pending, running, done, skipped, failed
    }

    struct Stage {
        let id: StageID
        var status: StageStatus = .pending
        var detail: String = ""
        /// nil means no meaningful percentage; the UI shows a spinner instead.
        var fraction: Double? = nil
        /// How many of the stage's lanes are held up by another stage.
        var waiters = 0
        /// Running, but only until another stage delivers.
        var isWaiting: Bool { status == .running && waiters > 0 }

        /// Whether the stage runs unseen: it waits on another stage, or it is the split
        /// reading ahead while elevation still downloads.
        func isHeld(among stages: [Stage]) -> Bool {
            guard status == .running else { return false }
            if waiters > 0 { return true }
            return id == .split && stages.contains { $0.id == .elevation && $0.status == .running }
        }

        /// The stage as the screen and the CLI report it: a held one has not started and
        /// has nothing to say.
        func shown(among stages: [Stage]) -> (status: StageStatus, detail: String) {
            isHeld(among: stages) ? (.pending, "") : (status, detail)
        }
        /// Moves the bar to a new position, never backwards. A stage runs several pieces of
        /// work, each counting from its own beginning.
        mutating func advance(to position: Double) {
            fraction = max(fraction ?? 0, min(1, position))
        }

        /// When it started and how long it took, for the summary the build ends with.
        var startedAt: Date?
        var seconds: Double = 0
        /// High-water memory while it ran.
        var peakBytes: Int64 = 0
    }
}
