import Foundation

/// Tells when jobs run side by side are doing nothing but waiting: at least 1 of them
/// waits on something outside, and every other has finished.
final class Idleness: Sendable {
    private struct State {
        var unfinished: Int
        var waiting = 0
        var idle: Bool { waiting > 0 && waiting == unfinished }
    }

    private let state: Locked<State>
    /// Called with true when the jobs fall idle and with false when work resumes, in the
    /// order it happened.
    private let changed: @Sendable (Bool) -> Void

    init(jobs: Int, changed: @escaping @Sendable (Bool) -> Void) {
        state = Locked(State(unfinished: jobs))
        self.changed = changed
    }

    /// A job is done.
    func finished() {
        change { $0.unfinished = max(0, $0.unfinished - 1) }
    }

    /// Runs `body`, in which a job only waits.
    func waiting<T>(_ body: () throws -> T) rethrows -> T {
        change { $0.waiting += 1 }
        defer { change { $0.waiting = max(0, $0.waiting - 1) } }
        return try body()
    }

    private func change(_ body: (inout State) -> Void) {
        state.withLock {
            let was = $0.idle
            body(&$0)
            if $0.idle != was { changed($0.idle) }
        }
    }
}
