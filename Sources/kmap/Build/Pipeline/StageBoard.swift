import Foundation

/// The stages of a build as every thread sees them: the run writes, a progress monitor
/// writes from its own task, and the screen and the CLI read.
///
/// Apart from the pipeline so that a monitor can hold this and nothing else: it is
/// `Sendable`, which the pipeline itself is not.
final class StageBoard: Sendable {
    typealias StageID = BuildPipeline.StageID
    typealias Stage = BuildPipeline.Stage
    typealias StageStatus = BuildPipeline.StageStatus

    private struct State {
        var stages: [StageID: Stage]
        /// The furthest the whole build's bar has reached, so it never moves backwards.
        var overallHighWater = 0.0
        /// Set when the build ends: a task still winding down changes nothing after it.
        var closed = false
    }

    private let state: Locked<State>

    init() {
        state = Locked(
            State(
                stages: Dictionary(
                    uniqueKeysWithValues: StageID.allCases.map { ($0, Stage(id: $0)) }
                )
            )
        )
    }

    // MARK: Reading

    func status(of id: StageID) -> StageStatus {
        state.withLock { $0.stages[id]?.status ?? .pending }
    }

    func detail(of id: StageID) -> String? {
        state.withLock { $0.stages[id]?.detail }
    }

    /// Every stage, in the order they run.
    var stages: [Stage] {
        state.withLock { state in StageID.allCases.compactMap { state.stages[$0] } }
    }

    /// The stages running right now.
    var running: [StageID] {
        stages.filter { $0.status == .running }.map(\.id)
    }

    /// Raises the high-water mark to `overall` and returns it: whatever the stages say,
    /// the whole build's bar only ever moves forward.
    func floor(raisedTo overall: Double) -> Double {
        state.withLock {
            $0.overallHighWater = max($0.overallHighWater, overall)
            return $0.overallHighWater
        }
    }

    // MARK: Writing

    func set(_ id: StageID, _ status: StageStatus, _ detail: String? = nil, fraction: Double? = nil) {
        // Read outside the lock: it asks the system, and nothing here depends on it.
        let ending = status == .done || status == .failed
        let peak = ending ? Machine.memoryInUse() : 0
        state.withLock {
            guard !$0.closed else { return }
            var stage = $0.stages[id] ?? Stage(id: id)
            if status == .running, stage.status != .running {
                // Starting, or restarting after a re-split: the bar begins from here.
                if stage.startedAt == nil { stage.startedAt = Date() }
                stage.fraction = nil
            }
            if ending {
                if let started = stage.startedAt { stage.seconds = Date().timeIntervalSince(started) }
                stage.peakBytes = peak
            }
            stage.status = status
            if let detail { stage.detail = detail }
            if let fraction { stage.advance(to: fraction) }
            $0.stages[id] = stage
        }
    }

    /// Clears the progress fraction for a stage that has moved on to a different piece of
    /// work. `advance(to:)` only ever moves forward, which is wrong across two pieces.
    func beginPhase(_ id: StageID, _ text: String) {
        change(id) {
            $0.detail = text
            $0.fraction = nil
        }
    }

    /// Runs `body` with the stage held, not shown as working. Several lanes of a stage
    /// may wait at once; it reads as working again when none does.
    func waiting<T: Sendable>(_ id: StageID, until body: @Sendable () async throws -> T) async rethrows -> T {
        beginWaiting(id)
        defer { endWaiting(id) }
        return try await body()
    }

    /// 1 more lane of the stage only waits on another stage; paired with `endWaiting`.
    func beginWaiting(_ id: StageID) {
        change(id) { $0.waiters += 1 }
    }

    func endWaiting(_ id: StageID) {
        change(id) { $0.waiters = max(0, $0.waiters - 1) }
    }

    /// 1 more lane of the stage at work, as a region of the split; paired with `endLane`.
    func beginLane(_ id: StageID) {
        change(id) { $0.lanes += 1 }
    }

    func endLane(_ id: StageID) {
        change(id) { $0.lanes = max(0, $0.lanes - 1) }
    }

    /// Ends a build that did not finish: every stage at work is marked failed with
    /// `reason`. A held stage was never shown as started, so it goes back to pending.
    /// Closes the board in the same step, so nothing winding down starts a stage again.
    func stop(_ reason: String) {
        let ending = Machine.memoryInUse()
        state.withLock { state in
            let all = StageID.allCases.compactMap { state.stages[$0] }
            for var stage in all where stage.status == .running {
                if stage.isHeld(among: all) {
                    stage.status = .pending
                    stage.detail = ""
                    stage.fraction = nil
                    stage.startedAt = nil
                } else {
                    stage.status = .failed
                    stage.detail = reason
                    if let started = stage.startedAt { stage.seconds = Date().timeIntervalSince(started) }
                    stage.peakBytes = ending
                }
                stage.waiters = 0
                stage.lanes = 0
                state.stages[stage.id] = stage
            }
            state.closed = true
        }
    }

    /// Moves a stage's bar forward without touching its detail line.
    func advance(_ id: StageID, fraction: Double) {
        change(id) { $0.advance(to: fraction) }
    }

    func detail(_ id: StageID, _ text: String, fraction: Double? = nil) {
        change(id) {
            $0.detail = text
            if let fraction { $0.advance(to: fraction) }
        }
    }

    /// The stages as they are now, for good.
    func close() {
        state.withLock { $0.closed = true }
    }

    private func change(_ id: StageID, _ body: (inout Stage) -> Void) {
        state.withLock {
            guard !$0.closed else { return }
            var stage = $0.stages[id] ?? Stage(id: id)
            body(&stage)
            $0.stages[id] = stage
        }
    }
}
