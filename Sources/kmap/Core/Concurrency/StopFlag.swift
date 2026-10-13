import Foundation

/// A task's cancellation, readable where `Task.isCancelled` is not: on the GCD threads
/// `concurrentPerform` runs work on. The task raises it from its cancellation handler.
final class StopFlag: Sendable {
    private let raised = Locked(false)

    func raise() { raised.withLock { $0 = true } }

    var isRaised: Bool { raised.withLock { $0 } }
}
