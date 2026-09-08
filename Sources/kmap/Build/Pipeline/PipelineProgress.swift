import Foundation

/// What a build says about itself while it runs: the stage list, each
/// stage's status, detail line and bar, the timed pieces of work inside it,
/// and the snapshot every screen and the CLI read.
extension BuildPipeline {

    enum StageID: String, CaseIterable {
        case preflight, download, elevation, elevationBuild, split, compile, collect

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
            case .download: return t("Download OSM extract")
            case .elevation: return t("Download elevation")
            case .elevationBuild: return t("Contours and DEM")
            case .split: return t("Split into tiles")
            case .compile: return t("Compile map")
            case .collect: return t("Write output")
            }
        }
    }

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
                .preflight: 0.01, .download: 0.24, .elevation: 0.20, .elevationBuild: 0.10,
                .split: 0.15, .compile: 0.28, .collect: 0.02
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

    /// The current status of a stage. Read under `lock`.
    func status(of id: StageID) -> StageStatus {
        lock.lock()
        defer { lock.unlock() }
        return stages[id]?.status ?? .pending
    }

    func snapshot() -> Snapshot {
        lock.lock()
        defer { lock.unlock() }
        var made = Snapshot(stages: StageID.allCases.compactMap { stages[$0] },
                            finished: finished,
                            failure: failure,
                            cancelled: wasCancelled,
                            outputs: outputs,
                            startedAt: startedAt,
                            finishedAt: finishedAt)
        // Whatever the stages say, the whole build's bar only ever moves forward.
        overallHighWater = max(overallHighWater, made.rawOverall)
        made.overallFloor = overallHighWater
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

    /// Kept apart from `measure` so the lock is never taken from an async function.
    func record(_ stage: StageID, _ name: String, _ seconds: Double) {
        lock.lock()
        defer { lock.unlock() }
        if let at = marks.firstIndex(where: { $0.stage == stage && $0.name == name }) {
            marks[at].seconds += seconds
            marks[at].peakBytes = Machine.memoryInUse()
        } else {
            marks.append(Mark(stage: stage, name: name, seconds: seconds,
                              peakBytes: Machine.memoryInUse()))
        }
    }

    func set(_ id: StageID, _ status: StageStatus, _ detail: String? = nil, fraction: Double? = nil) {
        lock.lock()
        var stage = stages[id] ?? Stage(id: id)
        if status == .running, stage.status != .running {
            // Starting, or restarting after a re-split: the bar begins from here.
            if stage.startedAt == nil { stage.startedAt = Date() }
            stage.fraction = nil
        }
        if status == .done || status == .failed {
            if let started = stage.startedAt { stage.seconds = Date().timeIntervalSince(started) }
            stage.peakBytes = Machine.memoryInUse()
        }
        stage.status = status
        if let detail { stage.detail = detail }
        if let fraction { stage.advance(to: fraction) }
        stages[id] = stage
        lock.unlock()
    }

    /// Clears the progress fraction for a stage that has moved on to a different piece of
    /// work. `advance(to:)` only ever moves forward, which is wrong across two pieces.
    func beginPhase(_ id: StageID, _ text: String) {
        lock.lock()
        var stage = stages[id] ?? Stage(id: id)
        stage.detail = text
        stage.fraction = nil
        stages[id] = stage
        lock.unlock()
    }

    /// Moves a stage's bar forward without touching its detail line.
    func advance(_ id: StageID, fraction: Double) {
        lock.lock()
        var stage = stages[id] ?? Stage(id: id)
        stage.advance(to: fraction)
        stages[id] = stage
        lock.unlock()
    }

    func detail(_ id: StageID, _ text: String, fraction: Double? = nil) {
        lock.lock()
        var stage = stages[id] ?? Stage(id: id)
        stage.detail = text
        if let fraction { stage.advance(to: fraction) }
        stages[id] = stage
        lock.unlock()
    }

    /// Logs what each stage cost, in the order they ran. The memory column is the
    /// high-water mark at the end of the stage.
    func reportTimings() {
        lock.lock()
        let ran = StageID.allCases.compactMap { stages[$0] }.filter { $0.seconds > 0 }
        lock.unlock()
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
