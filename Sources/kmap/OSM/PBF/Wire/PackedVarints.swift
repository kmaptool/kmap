import CVector
import Foundation

/// Packed varints, decoded straight into a buffer. Every value takes a byte at least,
/// so a buffer with room for as many values as there are bytes is always enough.
///
/// While 10 bytes are still ahead a varint is read without asking after the end of
/// the buffer at each byte; the last few, and any varint that runs past 10 bytes, go
/// through `ProtoReader`, so a malformed stream decodes as the reader decodes it.
enum PackedVarints {
    /// The longest varint: 7 bits a byte, 64 bits.
    private static let longest = 10

    /// A varint at `p`, which has `longest` readable bytes. Moves `p` past it and
    /// answers true; answers false, leaving `p`, where it does not end within them.
    /// A byte at a time, the first 3 written out: the lengths in a run of node deltas
    /// or way references repeat, and are predicted.
    @inline(__always)
    private static func next(_ p: inout UnsafePointer<UInt8>, _ value: inout UInt64) -> Bool {
        let b0 = UInt64(p[0])
        if b0 < 0x80 {
            value = b0
            p += 1
            return true
        }
        let b1 = UInt64(p[1])
        if b1 < 0x80 {
            value = (b0 & 0x7F) | b1 << 7
            p += 2
            return true
        }
        let b2 = UInt64(p[2])
        if b2 < 0x80 {
            value = (b0 & 0x7F) | (b1 & 0x7F) << 7 | b2 << 14
            p += 3
            return true
        }
        var result = (b0 & 0x7F) | (b1 & 0x7F) << 7 | (b2 & 0x7F) << 14
        var shift: UInt64 = 21
        for i in 3..<longest {
            let b = UInt64(p[i])
            result |= (b & 0x7F) << shift
            if b < 0x80 {
                value = result
                p += i + 1
                return true
            }
            shift += 7
        }
        return false
    }

    @inline(__always)
    private static func unzigzag(_ raw: UInt64) -> Int64 {
        Int64(bitPattern: raw >> 1) ^ -Int64(bitPattern: raw & 1)
    }

    /// Whether long fields go through the vector decoder first. Its tables are built
    /// on the first asking.
    private static let vectored: Bool = {
        kmap_varints_prepare()
        return kmap_vector_tier() != 0
    }()

    /// The vector decoder reads 64 bytes at a time; a shorter field is not worth the call.
    private static let leastVectored = 64

    /// The front of a long field through the vector decoder, which answers how many
    /// values it wrote and sets `used` to the bytes they took. Nothing for a short one.
    @inline(__always)
    private static func front(
        _ bytes: UnsafeRawBufferPointer,
        _ used: inout Int,
        _ decode: (UnsafePointer<UInt8>, Int, inout Int) -> Int
    ) -> Int {
        guard bytes.count >= leastVectored, vectored, let base = bytes.baseAddress else { return 0 }
        return decode(base.assumingMemoryBound(to: UInt8.self), bytes.count, &used)
    }

    /// Runs `body` over every varint of `bytes` from `from` on, in order.
    @inline(__always)
    private static func each(_ bytes: UnsafeRawBufferPointer, from: Int, _ body: (UInt64) -> Void) {
        guard let base = bytes.baseAddress, from < bytes.count else { return }
        let start = base.assumingMemoryBound(to: UInt8.self)
        var p = start + from
        if bytes.count - from >= longest {
            let fastEnd = start + (bytes.count - longest + 1)
            var value: UInt64 = 0
            while p < fastEnd, next(&p, &value) { body(value) }
        }
        var reader = ProtoReader(bytes, from: p - start)
        while !reader.isAtEnd { body(reader.varint()) }
    }

    /// Zigzag varints, as they stand. Answers how many were written.
    static func zigzag(_ bytes: UnsafeRawBufferPointer, into out: UnsafeMutablePointer<Int64>) -> Int {
        var used = 0
        var n = front(bytes, &used) { kmap_varints_zigzag64($0, $1, out, &$2) }
        each(bytes, from: used) { raw in
            out[n] = unzigzag(raw)
            n += 1
        }
        return n
    }

    /// Zigzag varints that are each a step from the one before: the running sum.
    /// Wrapping, so a corrupt stream gives a wrong id rather than a trap.
    static func zigzagSums(_ bytes: UnsafeRawBufferPointer, into out: UnsafeMutablePointer<Int64>) -> Int {
        var used = 0
        var sum: Int64 = 0
        var n = front(bytes, &used) { kmap_varints_zigzag64_sums($0, $1, out, &$2, &sum) }
        each(bytes, from: used) { raw in
            sum &+= unzigzag(raw)
            out[n] = sum
            n += 1
        }
        return n
    }

    /// Varints kept as their low 32 bits: string-table indices and member kinds.
    static func int32(_ bytes: UnsafeRawBufferPointer, into out: UnsafeMutablePointer<Int32>) -> Int {
        var used = 0
        var n = front(bytes, &used) { kmap_varints_low32($0, $1, out, &$2) }
        each(bytes, from: used) { raw in
            out[n] = Int32(truncatingIfNeeded: raw)
            n += 1
        }
        return n
    }
}
