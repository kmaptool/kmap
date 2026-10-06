import Foundation

/// The answer 1 caller of a patch renewal gets: the rebuild's, or false once the caller
/// is stopped, whichever comes first. Given once; a later one is dropped.
final class MkgmapPatchRenewalAnswer: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Bool, Never>?
    private var given: Bool?

    /// Waits on `continuation`, answered at once where the answer came first.
    func wait(_ continuation: CheckedContinuation<Bool, Never>) {
        lock.lock()
        if let given {
            lock.unlock()
            continuation.resume(returning: given)
            return
        }
        self.continuation = continuation
        lock.unlock()
    }

    /// Gives the answer. Returns whether it was the first.
    @discardableResult
    func give(_ value: Bool) -> Bool {
        lock.lock()
        guard given == nil else {
            lock.unlock()
            return false
        }
        given = value
        let waiting = continuation
        continuation = nil
        lock.unlock()
        waiting?.resume(returning: value)
        return true
    }
}
