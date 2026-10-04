import Foundation

/// Protobuf wire types used by OSM PBF.
enum Wire {
    static let varint = 0
    static let fixed64 = 1
    static let lengthDelimited = 2
    static let fixed32 = 5

    /// Bytes on the wire for the two fixed-width types.
    fileprivate static let fixed64Size = 8
    fileprivate static let fixed32Size = 4

    /// A varint carries seven bits per byte, the high bit saying another follows.
    static let varintPayloadBits: UInt64 = 7
    static let varintPayloadMask: UInt8 = 0x7F
    static let varintContinuation: UInt8 = 0x80

    /// A field key packs the number above the wire type.
    static let typeBits: UInt64 = 3
    static let typeMask: UInt64 = 7
}

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
