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
}

/// Reader for the protobuf subset an OSM PBF uses: varints, zigzag varints,
/// length-delimited bytes, packed repeats and 32-bit fixed. Works on raw memory and
/// allocates nothing per field. Input is untrusted: declared lengths are clamped to the
/// buffer, so a corrupt message yields nonsense values but never reads outside it.
struct ProtoReader {
    let bytes: UnsafeRawBufferPointer
    var index: Int

    /// A varint carries seven bits per byte, so 64 bits occupy at most ten bytes.
    private static let maxVarintBytes = 10

    /// Field keys pack the number above the wire type.
    private static let wireTypeBits: UInt64 = 3
    private static let wireTypeMask: UInt64 = 7

    init(_ bytes: UnsafeRawBufferPointer, from: Int = 0) {
        self.bytes = bytes
        self.index = from
    }

    var isAtEnd: Bool { index >= bytes.count }

    /// The next field's number and wire type, or nil at the end of the message.
    mutating func nextField() -> (number: Int, wire: Int)? {
        guard index < bytes.count else { return nil }
        let key = varint()
        return (number: Int(key >> Self.wireTypeBits), wire: Int(key & Self.wireTypeMask))
    }

    mutating func varint() -> UInt64 {
        var result: UInt64 = 0
        var shift: UInt64 = 0
        var read = 0
        while index < bytes.count, read < Self.maxVarintBytes {
            let byte = bytes[index]
            index += 1
            read += 1
            result |= UInt64(byte & 0x7F) << shift
            if byte & 0x80 == 0 { return result }
            shift += 7
        }
        // Truncated or over-long varint: step past the remaining continuation bytes so the
        // reader stops at a definite position.
        while index < bytes.count, bytes[index] & 0x80 != 0 { index += 1 }
        if index < bytes.count { index += 1 }
        return result
    }

    /// Reads a zigzag varint: the sign occupies the low bit. OSM stores deltas and
    /// coordinates this way.
    mutating func zigzag() -> Int64 {
        let raw = varint()
        return Int64(bitPattern: raw >> 1) ^ -Int64(bitPattern: raw & 1)
    }

    /// Returns a length-delimited field as a window on the same memory, without copying.
    /// The declared length is clamped to the bytes available.
    mutating func lengthDelimited() -> UnsafeRawBufferPointer {
        let declared = varint()
        let start = min(index, bytes.count)
        let available = bytes.count - start
        let count = declared > UInt64(available) ? available : Int(declared)
        index = start + count
        return UnsafeRawBufferPointer(rebasing: bytes[start..<index])
    }

    /// Skips the current field.
    mutating func skip(wire: Int) {
        switch wire {
        case Wire.varint: _ = varint()
        case Wire.fixed64: advance(by: Wire.fixed64Size)
        case Wire.lengthDelimited: _ = lengthDelimited()
        case Wire.fixed32: advance(by: Wire.fixed32Size)
        default: index = bytes.count           // unknown wire type: give up on the message
        }
    }

    /// Advances by a fixed width, never past the end of the buffer.
    private mutating func advance(by count: Int) {
        index = index > bytes.count - count ? bytes.count : index + count
    }
}

/// Protobuf writer. Appends into one contiguous buffer; nothing else is allocated.
struct ProtoWriter {
    private(set) var bytes: [UInt8] = []

    mutating func reserve(_ n: Int) { bytes.reserveCapacity(n) }

    /// Empties the buffer, keeping its capacity for reuse.
    mutating func reset() { bytes.removeAll(keepingCapacity: true) }

    mutating func varint(_ value: UInt64) {
        var v = value
        while v >= 0x80 {
            bytes.append(UInt8(v & 0x7F) | 0x80)
            v >>= 7
        }
        bytes.append(UInt8(v))
    }

    mutating func zigzag(_ value: Int64) {
        varint(UInt64(bitPattern: (value << 1) ^ (value >> 63)))
    }

    mutating func key(_ field: Int, _ wire: Int) {
        varint(UInt64(field << 3 | wire))
    }

    /// Writes an int64 field. Zero is omitted; a reader that sees no field reads zero.
    mutating func varintField(_ field: Int, _ value: Int64) {
        guard value != 0 else { return }
        key(field, Wire.varint)
        varint(UInt64(bitPattern: value))
    }

    mutating func bytesField(_ field: Int, _ value: [UInt8]) {
        key(field, Wire.lengthDelimited)
        varint(UInt64(value.count))
        bytes.append(contentsOf: value)
    }

    mutating func stringField(_ field: Int, _ value: String) {
        bytesField(field, Array(value.utf8))
    }

    /// Writes a submessage, whose length is known only once its body is written.
    mutating func message(_ field: Int, _ body: (inout ProtoWriter) -> Void) {
        var inner = ProtoWriter()
        body(&inner)
        bytesField(field, inner.bytes)
    }
}

extension ProtoWriter {
    /// Writes a sint64 field, zigzag-encoded. Zero is omitted.
    mutating func zigzagField(_ field: Int, _ value: Int64) {
        guard value != 0 else { return }
        key(field, Wire.varint)
        zigzag(value)
    }
}
