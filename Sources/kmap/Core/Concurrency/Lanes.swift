import Foundation

/// Work over many items spread across the cores in lanes of consecutive items. Each lane
/// writes only its own items, so nothing is locked, and the results come back in item
/// order whatever order the lanes finish in.
enum Lanes {
    /// `item(at)` for every index below `count`, in order.
    static func map<T>(_ count: Int, lanes: Int = Machine.cores, _ item: @Sendable (Int) -> T) -> [T] {
        guard count > 0 else { return [] }
        let span = (count + max(1, min(lanes, count)) - 1) / max(1, min(lanes, count))
        // As many lanes as the span needs: with the count not a multiple of the span, the
        // last lanes asked for would start past the end.
        let lanes = (count + span - 1) / span
        return [T](unsafeUninitializedCapacity: count) { buffer, initialized in
            nonisolated(unsafe) let out = buffer
            DispatchQueue.concurrentPerform(iterations: lanes) { lane in
                for at in (lane * span)..<min(count, (lane + 1) * span) {
                    (out.baseAddress! + at).initialize(to: item(at))
                }
            }
            initialized = count
        }
    }

    /// As above, with a scratch value each lane makes once and hands to every item it
    /// reads, so buffers are allocated once per lane rather than once per item.
    static func map<T, Scratch>(
        _ count: Int,
        lanes: Int = Machine.cores,
        scratch: @Sendable () -> Scratch,
        _ item: @Sendable (inout Scratch, Int) -> T
    ) -> [T] {
        guard count > 0 else { return [] }
        let span = (count + max(1, min(lanes, count)) - 1) / max(1, min(lanes, count))
        // As many lanes as the span needs: with the count not a multiple of the span, the
        // last lanes asked for would start past the end.
        let lanes = (count + span - 1) / span
        return [T](unsafeUninitializedCapacity: count) { buffer, initialized in
            nonisolated(unsafe) let out = buffer
            DispatchQueue.concurrentPerform(iterations: lanes) { lane in
                var held = scratch()
                for at in (lane * span)..<min(count, (lane + 1) * span) {
                    (out.baseAddress! + at).initialize(to: item(&held, at))
                }
            }
            initialized = count
        }
    }
}
