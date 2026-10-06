import Foundation

/// Protobuf wire types used by OSM PBF.
enum Wire {
    static let varint = 0
    static let fixed64 = 1
    static let lengthDelimited = 2
    static let fixed32 = 5

    /// Bytes on the wire for the 2 fixed-width types.
    static let fixed64Size = 8
    static let fixed32Size = 4

    /// A varint carries 7 bits per byte, the high bit saying another follows.
    static let varintPayloadBits: UInt64 = 7
    static let varintPayloadMask: UInt8 = 0x7F
    static let varintContinuation: UInt8 = 0x80

    /// A field key packs the number above the wire type.
    static let typeBits: UInt64 = 3
    static let typeMask: UInt64 = 7
}
