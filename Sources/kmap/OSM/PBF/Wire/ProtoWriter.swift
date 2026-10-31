import Foundation

/// Writes protobuf into one contiguous buffer; nothing else is allocated.
struct ProtoWriter {
    private(set) var bytes: [UInt8] = []

    mutating func reserve(_ n: Int) { bytes.reserveCapacity(n) }

    /// Empties the buffer, keeping its capacity.
    mutating func reset() { bytes.removeAll(keepingCapacity: true) }

    mutating func varint(_ value: UInt64) {
        var v = value
        while v > UInt64(Wire.varintPayloadMask) {
            bytes.append(UInt8(v & UInt64(Wire.varintPayloadMask)) | Wire.varintContinuation)
            v >>= Wire.varintPayloadBits
        }
        bytes.append(UInt8(v))
    }

    mutating func zigzag(_ value: Int64) {
        varint(UInt64(bitPattern: (value << 1) ^ (value >> (Int64.bitWidth - 1))))
    }

    mutating func key(_ field: Int, _ wire: Int) {
        varint(UInt64(field) << Wire.typeBits | UInt64(wire))
    }

    /// An int64 field, zero included: the PBF fields written here are required.
    mutating func varintField(_ field: Int, _ value: Int64) {
        key(field, Wire.varint)
        varint(UInt64(bitPattern: value))
    }

    /// A sint64 field, zigzag-encoded, zero included: mkgmap refuses a header box missing a corner.
    mutating func zigzagField(_ field: Int, _ value: Int64) {
        key(field, Wire.varint)
        zigzag(value)
    }

    mutating func bytesField(_ field: Int, _ value: [UInt8]) {
        key(field, Wire.lengthDelimited)
        varint(UInt64(value.count))
        bytes.append(contentsOf: value)
    }

    mutating func stringField(_ field: Int, _ value: String) {
        bytesField(field, Array(value.utf8))
    }

    /// A submessage, whose length is known only once its body is written.
    mutating func message(_ field: Int, _ body: (inout ProtoWriter) -> Void) {
        var inner = ProtoWriter()
        body(&inner)
        bytesField(field, inner.bytes)
    }
}
