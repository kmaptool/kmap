import Foundation

/// Grid cell keys, each with a run of entries, built once and then only read. Open
/// addressing over flat storage: a lookup hashes with 1 multiply rather than SipHash,
/// and lookups from many threads at once share no reference count.
final class CellTable: @unchecked Sendable {
    /// No key `RoadRepair.key` makes: its latitude half would be 2^31 cells south.
    private static let empty = Int64.min
    /// The fewest slots, and slots per key: at most half full, so a probe stays short.
    private static let leastSlots = 16
    private static let slotsPerKey = 2
    /// 2^64 over the golden ratio: a multiply by it spreads neighbouring keys apart.
    private static let spread: UInt64 = 0x9E37_79B9_7F4A_7C15

    private let mask: Int
    private let shift: UInt64
    private let keys: UnsafeMutablePointer<Int64>
    /// Per slot, its run in `entries`: `starts[slot] ..< starts[slot] + counts[slot]`.
    private let starts: UnsafeMutablePointer<Int32>
    private let counts: UnsafeMutablePointer<Int32>
    private let entries: UnsafeMutablePointer<Int32>
    private let capacity: Int

    /// Files `values[i]` under `keys[i]`, each key's run in the order given. Without
    /// values, the table only answers `contains`.
    init(keys given: [Int64], values: [Int32] = []) {
        var size = Self.leastSlots
        while size < given.count * Self.slotsPerKey { size *= 2 }
        capacity = size
        mask = size - 1
        shift = UInt64(UInt64.bitWidth - size.trailingZeroBitCount)
        keys = .allocate(capacity: size)
        keys.initialize(repeating: Self.empty, count: size)
        starts = .allocate(capacity: size)
        starts.initialize(repeating: 0, count: size)
        counts = .allocate(capacity: size)
        counts.initialize(repeating: 0, count: size)
        entries = .allocate(capacity: max(values.count, 1))

        var slots = [Int32](repeating: 0, count: given.count)
        for (i, key) in given.enumerated() {
            let slot = place(key)
            slots[i] = Int32(slot)
            counts[slot] += 1
        }
        guard !values.isEmpty else { return }
        var at: Int32 = 0
        for slot in 0..<size where counts[slot] > 0 {
            starts[slot] = at
            at += counts[slot]
        }
        var filled = [Int32](repeating: 0, count: size)
        for (i, slot) in slots.enumerated() {
            let s = Int(slot)
            entries[Int(starts[s] + filled[s])] = values[i]
            filled[s] += 1
        }
    }

    deinit {
        keys.deallocate()
        starts.deallocate()
        counts.deallocate()
        entries.deallocate()
    }

    @inline(__always)
    private func home(_ key: Int64) -> Int {
        Int(truncatingIfNeeded: (UInt64(bitPattern: key) &* Self.spread) >> shift)
    }

    /// The slot holding `key`, made if new.
    private func place(_ key: Int64) -> Int {
        var slot = home(key)
        while true {
            if keys[slot] == key { return slot }
            if keys[slot] == Self.empty {
                keys[slot] = key
                return slot
            }
            slot = (slot + 1) & mask
        }
    }

    @inline(__always)
    private func find(_ key: Int64) -> Int? {
        var slot = home(key)
        while true {
            let here = keys[slot]
            if here == key { return slot }
            if here == Self.empty { return nil }
            slot = (slot + 1) & mask
        }
    }

    func contains(_ key: Int64) -> Bool { find(key) != nil }

    /// The entries filed under `key`, in the order they were given; empty if none.
    @inline(__always)
    func run(_ key: Int64) -> UnsafeBufferPointer<Int32> {
        guard let slot = find(key) else { return UnsafeBufferPointer(start: nil, count: 0) }
        return UnsafeBufferPointer(start: entries + Int(starts[slot]), count: Int(counts[slot]))
    }
}
