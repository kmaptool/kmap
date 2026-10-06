import Foundation

/// Reads the protobuf subset an OSM PBF uses: varints, zigzag varints, length-delimited
/// bytes, packed repeats and 32-bit fixed. Works on raw memory and allocates nothing per
/// field. Input is untrusted: a declared length is clamped to the buffer, so a corrupt
/// message yields nonsense but never reads outside it.
struct ProtoReader {
    let bytes: UnsafeRawBufferPointer
    var index: Int

    /// Seven bits per byte, so 64 bits take at most ten.
    private static let maxVarintBytes = 10

    init(_ bytes: UnsafeRawBufferPointer, from: Int = 0) {
        self.bytes = bytes
        self.index = from
    }

    var isAtEnd: Bool { index >= bytes.count }

    /// The next field's number and wire type, or nil at the end of the message.
    mutating func nextField() -> (number: Int, wire: Int)? {
        guard index < bytes.count else { return nil }
        let key = varint()
        return (number: Int(key >> Wire.typeBits), wire: Int(key & Wire.typeMask))
    }

    mutating func varint() -> UInt64 {
        // Field keys, lengths and small numbers: 1 byte, read without the loop.
        if index < bytes.count, bytes[index] < Wire.varintContinuation {
            index += 1
            return UInt64(bytes[index - 1])
        }
        var result: UInt64 = 0
        var shift: UInt64 = 0
        var read = 0
        while index < bytes.count, read < Self.maxVarintBytes {
            let byte = bytes[index]
            index += 1
            read += 1
            result |= UInt64(byte & Wire.varintPayloadMask) << shift
            if byte & Wire.varintContinuation == 0 { return result }
            shift += Wire.varintPayloadBits
        }
        // Truncated or over-long: step past the remaining continuation bytes so the
        // reader stops at a definite position.
        while index < bytes.count, bytes[index] & Wire.varintContinuation != 0 { index += 1 }
        if index < bytes.count { index += 1 }
        return result
    }

    /// A zigzag varint: the sign is the low bit. OSM stores deltas and coordinates so.
    mutating func zigzag() -> Int64 {
        let raw = varint()
        return Int64(bitPattern: raw >> 1) ^ -Int64(bitPattern: raw & 1)
    }

    /// A length-delimited field as a window on the same memory, without copying. The
    /// declared length is clamped to the bytes available.
    mutating func lengthDelimited() -> UnsafeRawBufferPointer {
        let declared = varint()
        let start = min(index, bytes.count)
        let available = bytes.count - start
        let count = declared > UInt64(available) ? available : Int(declared)
        index = start + count
        return UnsafeRawBufferPointer(rebasing: bytes[start..<index])
    }

    /// Skips the current field. An unknown wire type gives up on the message.
    mutating func skip(wire: Int) {
        switch wire {
        case Wire.varint: _ = varint()
        case Wire.fixed64: advance(by: Wire.fixed64Size)
        case Wire.lengthDelimited: _ = lengthDelimited()
        case Wire.fixed32: advance(by: Wire.fixed32Size)
        default: index = bytes.count
        }
    }

    /// Advances by a fixed width, never past the end of the buffer.
    private mutating func advance(by count: Int) {
        index = index > bytes.count - count ? bytes.count : index + count
    }
}
