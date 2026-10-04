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
        /// How many of the stage's lanes are held up by another stage, and how many are at
        /// work: the regions the split annotates side by side. 0 lanes counts as 1.
        var waiters = 0
        var lanes = 0
        /// Running, but every lane only until another stage delivers: 1 region waiting
        /// while another still scans is work.
        var isWaiting: Bool { status == .running && waiters > 0 && waiters >= max(1, lanes) }

        /// Whether the stage runs unseen: it waits on another stage, or it is the split
        /// reading ahead while elevation still downloads.
        func isHeld(among stages: [Stage]) -> Bool {
            guard status == .running else { return false }
            if isWaiting { return true }
            return id == .split && stages.contains { $0.id == .elevation && $0.status == .running }
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
