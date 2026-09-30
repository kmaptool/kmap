import Foundation

/// The installs in flight and the ones waiting their turn. One that fetches what another
/// is fetching waits for it: the patch pulls mkgmap in on its own, and two of those into
/// one folder would be a mess.
@MainActor
final class InstallQueue {
    /// One install in flight: what its row draws, and what stops it.
    final class Job {
        let progress = InstallProgress()
        let runner = ProcessRunner()
        var task: Task<Void, Never>?

        /// The process a step may be running, and the task, through which cancellation
        /// reaches a download.
        func stop() {
            task?.cancel()
            runner.cancel()
        }
    }

    private(set) var running: [String: Job] = [:]
    /// Waiting for an install that overlaps theirs, in the order they were asked for.
    private(set) var waiting: [String] = []

    var isBusy: Bool { !running.isEmpty || !waiting.isEmpty }

    func isInstalling(_ id: String) -> Bool {
        running[id] != nil || waiting.contains(id)
    }

    func isWaiting(_ id: String) -> Bool { waiting.contains(id) }

    /// The running and earlier-queued installs `id` overlaps with.
    func blockers(of id: String, ahead: [String]) -> [String] {
        (running.keys.sorted() + ahead).filter { Toolchain.overlap(id, $0) }
    }

    /// Those in the way of `id`, whether it is queued already or about to be.
    func blockerNames(of id: String, named name: (String) -> String) -> [String] {
        blockers(of: id, ahead: waiting.prefix { $0 != id }).map(name)
    }

    /// Whether `id` can start now; otherwise it joins the queue.
    func admit(_ id: String) -> Bool {
        guard blockers(of: id, ahead: waiting).isEmpty else {
            waiting.append(id)
            return false
        }
        return true
    }

    func begin(_ id: String) -> Job {
        let job = Job()
        running[id] = job
        return job
    }

    func finish(_ id: String) {
        running.removeValue(forKey: id)
    }

    /// The first queued install nothing overlaps any more, taken off the queue.
    func takeReady() -> String? {
        for (at, id) in waiting.enumerated()
        where blockers(of: id, ahead: Array(waiting.prefix(at))).isEmpty {
            waiting.remove(at: at)
            return id
        }
        return nil
    }

    func stopAll() {
        for job in running.values { job.stop() }
        waiting.removeAll()
    }
}
