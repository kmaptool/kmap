import Foundation

/// What a build says about itself while it runs: the stage list, each
/// stage's status, detail line and bar, the timed pieces of work inside it,
/// and the snapshot every screen and the CLI read.
extension BuildPipeline {
    /// How often a running download repaints its stage line. Fast enough to look live,
    /// slow enough not to fight the render loop.
    static let progressTick: UInt64 = 200_000_000

    func status(of id: StageID) -> StageStatus { board.status(of: id) }

    func snapshot() -> Snapshot {
        let run = state.withLock { $0 }
        var made = Snapshot(
            stages: board.stages,
            finished: run.finished,
            failure: run.failure,
            cancelled: run.wasCancelled,
            outputs: run.outputs,
            startedAt: run.startedAt,
            finishedAt: run.finishedAt
        )
        made.overallFloor = board.floor(raisedTo: made.rawOverall)
        return made
    }

    /// A named piece of work inside a stage, timed for the end-of-build summary.
    struct Mark {
        let stage: StageID
        let name: String
        var seconds: Double
        var peakBytes: Int64
    }

    /// Times a piece of work and files it under its stage.
    func measure<T>(
        _ stage: StageID,
        _ name: String,
        _ work: () async throws -> T
    ) async rethrows -> T {
        let started = Date()
        let result = try await work()
        record(stage, name, Date().timeIntervalSince(started))
        return result
    }

    func record(_ stage: StageID, _ name: String, _ seconds: Double) {
        let peak = Machine.memoryInUse()
        state.withLock { run in
            if let at = run.marks.firstIndex(where: { $0.stage == stage && $0.name == name }) {
                run.marks[at].seconds += seconds
                run.marks[at].peakBytes = peak
            } else {
                run.marks.append(Mark(stage: stage, name: name, seconds: seconds, peakBytes: peak))
            }
        }
    }

    // The stages live on the board; these forward, so a stage reads as it always did.

    func set(_ id: StageID, _ status: StageStatus, _ detail: String? = nil, fraction: Double? = nil) {
        board.set(id, status, detail, fraction: fraction)
    }

    func beginPhase(_ id: StageID, _ text: String) { board.beginPhase(id, text) }

    /// Runs `body` with the stage held: it only waits on another stage.
    func waiting<T: Sendable>(
        _ id: StageID,
        until body: @Sendable () async throws -> T
    ) async rethrows -> T {
        try await board.waiting(id, until: body)
    }

    func advance(_ id: StageID, fraction: Double) { board.advance(id, fraction: fraction) }

    func detail(_ id: StageID, _ text: String, fraction: Double? = nil) {
        board.detail(id, text, fraction: fraction)
    }

    /// Logs what each stage cost, in the order they ran. The memory column is the
    /// high-water mark at the end of the stage.
    func reportTimings() {
        let ran = board.stages.filter { $0.seconds > 0 }
        let marks = state.withLock { $0.marks }
        guard !ran.isEmpty else { return }
        let total = ran.reduce(0.0) { $0 + $1.seconds }
        guard total > 1 else { return }

        let width =
            max(
                ran.map { $0.id.title.count }.max() ?? 12,
                (marks.map { $0.name.count + 2 }.max() ?? 0)
            ) + 2
        func padded(_ text: String) -> String {
            text + String(repeating: " ", count: max(1, width - text.count))
        }

        log.append("")
        log.append("where the time went")
        for stage in ran {
            let share = Int((stage.seconds / total * 100).rounded())
            log.append(
                "  " + padded(stage.id.title)
                    + String(
                        format: "%6.1f s  %3d%%   up to %@",
                        stage.seconds,
                        share,
                        Fmt.bytes(stage.peakBytes)
                    )
            )
            for mark in marks where mark.stage == stage.id && mark.seconds >= 0.05 {
                log.append(
                    "    " + padded("· " + mark.name)
                        + String(format: "%6.1f s", mark.seconds)
                )
            }
        }
        log.append("  " + padded("in all") + String(format: "%6.1f s", total))
    }
}
