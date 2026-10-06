import Foundation

/// 1 rebuild of the mkgmap patch and how many callers wait on it, counted apart from the
/// next rebuild's.
final class MkgmapPatchRenewal: @unchecked Sendable {
    private let lock = NSLock()
    private var waiting = 1
    /// Set once, as the renewal is made.
    var task: Task<(renewed: Bool, failure: String?), Never>!

    /// Waits on it too. False once its last caller has left: it is being stopped.
    func join() -> Bool {
        lock.withLock {
            guard waiting > 0 else { return false }
            waiting += 1
            return true
        }
    }

    /// A caller is done with it. Returns whether it was the last.
    func leave() -> Bool {
        lock.withLock {
            waiting -= 1
            return waiting == 0
        }
    }
}
