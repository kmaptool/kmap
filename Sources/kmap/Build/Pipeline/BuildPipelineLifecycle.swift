import Foundation

extension BuildPipeline {
    func start() {
        // One step, so 2 callers cannot both start it.
        let alreadyStarted = state.withLock { run -> Bool in
            guard run.task == nil else { return true }
            run.startedAt = Date()
            run.task = Task.detached(priority: .userInitiated) { [weak self] in
                await self?.run()
            }
            return false
        }
        _ = alreadyStarted
    }

    func cancel() {
        let active = state.withLock { run -> Run in
            run.wasCancelled = true
            return run
        }
        log.warn("cancelling…")
        for runner in active.runners { runner.cancel() }
        for downloader in active.downloaders { downloader.cancel() }
        active.elevation?.cancel()
        active.task?.cancel()
    }

    /// Also true while kmap is leaving and takes its tools along.
    var isCancelled: Bool { wasCancelled || ChildProcess.isLeaving }

    /// For work on its own threads, which task cancellation misses; also true while the
    /// elevation is being stopped.
    var stopAsked: @Sendable () -> Bool {
        { [weak self] in self.map { $0.state.withLock { $0.wasCancelled || $0.settling } } ?? true }
    }

    /// A stage can end early for its own reasons, such as a killed tool or a dropped
    /// download, and the next must not start.
    func stopIfCancelled() throws {
        if isCancelled || Task.isCancelled { throw CancellationError() }
    }

    /// A tool killed by `cancel()`, not one that failed.
    private func isRunnerCancellation(_ error: Error) -> Bool {
        if case ProcessRunner.RunError.cancelled = error { return true }
        return false
    }

    /// Stages go on without contours, summit heights or annotation, but a cancellation
    /// is thrown on.
    func rethrowIfCancelled(_ error: Error) throws {
        if error is CancellationError
            || isRunnerCancellation(error)
            || (error as? URLError)?.code == .cancelled
            || isCancelled || Task.isCancelled
        {
            throw CancellationError()
        }
    }

    func publish(_ written: [Output]) {
        state.withLock { $0.outputs = written }
    }

    func retain(_ downloader: Downloader) {
        state.withLock { $0.downloaders.append(downloader) }
    }

    /// Registered after a cancel, it is cancelled on the spot: the 2 can race.
    func retain(elevation task: Task<[URL], Error>) {
        let cancelled = state.withLock { run -> Bool in
            run.elevation = task
            return run.wasCancelled
        }
        if cancelled { task.cancel() }
    }

    /// Stops the elevation task and waits for it. Stopped for a rerun, its stages go back
    /// to pending; stopped by a failure, they stay for `finish`.
    func settleElevation(puttingStagesBack: Bool = true) async {
        // Its threads see only `stopAsked`, not the task's cancellation.
        let task = state.withLock { run in
            run.settling = true
            return run.elevation
        }
        task?.cancel()
        _ = await task?.result
        state.withLock { $0.settling = false }
        guard puttingStagesBack else { return }
        for id in [StageID.elevation, .elevationBuild] where board.status(of: id) == .running {
            set(id, .pending, "")
        }
    }

    func makeRunner() -> ProcessRunner {
        let runner = ProcessRunner()
        state.withLock { $0.runners.append(runner) }
        return runner
    }

    func finish(error: Error?) {
        let wasCancelled = state.withLock { run -> Bool in
            run.finishedAt = Date()
            // With its maps in place, a stop asked at the last step does not count.
            if error == nil { run.wasCancelled = false }
            if let error {
                if run.wasCancelled || error is CancellationError {
                    run.wasCancelled = true
                } else {
                    run.failure = ErrorWords.of(error)
                }
            }
            return run.wasCancelled
        }

        // Otherwise the running stage keeps its spinner and reads as still working.
        if error != nil { board.stop(wasCancelled ? t("cancelled") : t("failed")) }

        if let error, !(error is CancellationError), !wasCancelled {
            log.error(ErrorWords.of(error))
        } else if wasCancelled {
            log.warn("build cancelled")
        } else {
            log.ok("build finished")
            if Measured.reported { reportTimings() }
        }
        // A task still winding down, like the elevation, changes no stage after this.
        board.close()
        // Last, so whoever watches for the end finds every stage and line.
        state.withLock { $0.finished = true }
    }
}
