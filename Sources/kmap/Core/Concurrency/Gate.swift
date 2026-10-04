import Foundation

/// A value that arrives once. Whoever asks before it arrives waits; whoever asks after
/// has it at once. A second `open` is ignored.
final class Gate<Value: Sendable>: Sendable {
    private struct State {
        var value: Value?
        var waiting: [CheckedContinuation<Value, Never>] = []
    }

    private let state = Locked(State())

    func open(_ value: Value) {
        let waiting = state.withLock { state -> [CheckedContinuation<Value, Never>] in
            guard state.value == nil else { return [] }
            state.value = value
            defer { state.waiting = [] }
            return state.waiting
        }
        for waiter in waiting { waiter.resume(returning: value) }
    }

    /// Whether the value has arrived, so asking for it does not wait.
    var isOpen: Bool { state.withLock { $0.value != nil } }

    var value: Value {
        get async {
            await withCheckedContinuation { waiter in
                let now = state.withLock { state -> Value? in
                    if let value = state.value { return value }
                    state.waiting.append(waiter)
                    return nil
                }
                if let now { waiter.resume(returning: now) }
            }
        }
    }
}
