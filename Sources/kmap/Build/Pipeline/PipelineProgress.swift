import Foundation

/// What a build says about itself while it runs: the stage list, each
/// stage's status, detail line and bar, the timed pieces of work inside it,
/// and the snapshot every screen and the CLI read.
extension BuildPipeline {

    enum StageID: String, CaseIterable {
        case preflight, dataUpdate, download, elevation, elevationBuild, split,
             compile, collect

        /// Whether this stage runs concurrently with the others rather than before them.
        /// The elevation stages start once the extracts are down and run beside the split.
        var runsBeside: Bool {
            switch self {
            case .elevation, .elevationBuild: return true
            default: return false
            }
        }

        var title: String {
            switch self {
            case .preflight: return t("Check tools and disk")
            case .dataUpdate: return t("Update tools")
            case .download: return t("Download OSM extract")
            case .elevation: return t("Download elevation")
            case .elevationBuild: return t("Contours and DEM")
            case .split: return t("Split into tiles")
            case .compile: return t("Compile map")
            case .collect: return t("Write output")
            }
        }
    }

    /// How often a running download repaints its stage line. Fast enough to look live,
    /// slow enough not to fight the render loop.
    static let progressTick: UInt64 = 200_000_000

    enum StageStatus: String {
        case pending, running, done, skipped, failed
    }

    struct Stage {
        let id: StageID
        var status: StageStatus = .pending
        var detail: String = ""
        /// nil means no meaningful percentage; the UI shows a spinner instead.
        var fraction: Double? = nil
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

    func status(of id: StageID) -> StageStatus { board.status(of: id) }

    func snapshot() -> Snapshot {
        let run = state.withLock { $0 }
        var made = Snapshot(stages: board.stages,
                            finished: run.finished,
                            failure: run.failure,
                            cancelled: run.wasCancelled,
                            outputs: run.outputs,
                            startedAt: run.startedAt,
                            finishedAt: run.finishedAt)
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
    func measure<T>(_ stage: StageID, _ name: String,
                            _ work: () async throws -> T) async rethrows -> T {
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

        let width = max(ran.map { $0.id.title.count }.max() ?? 12,
                        (marks.map { $0.name.count + 2 }.max() ?? 0)) + 2
        func padded(_ text: String) -> String {
            text + String(repeating: " ", count: max(1, width - text.count))
        }

        log.append("")
        log.append("where the time went")
        for stage in ran {
            let share = Int((stage.seconds / total * 100).rounded())
            log.append("  " + padded(stage.id.title)
                       + String(format: "%6.1f s  %3d%%   up to %@",
                                stage.seconds, share, Fmt.bytes(stage.peakBytes)))
            for mark in marks where mark.stage == stage.id && mark.seconds >= 0.05 {
                log.append("    " + padded("· " + mark.name)
                           + String(format: "%6.1f s", mark.seconds))
            }
        }
        log.append("  " + padded("in all") + String(format: "%6.1f s", total))
    }
}
