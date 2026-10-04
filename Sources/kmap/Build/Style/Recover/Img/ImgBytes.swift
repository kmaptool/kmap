import Foundation

extension ImgElements {
    /// A cursor over a subfile's bytes, little-endian, with the three-byte reads the
    /// format is made of. An array, so the bit reader can look into it by offset with
    /// nothing borrowed from a closure.
    /// Every offset and length comes from the file, so a read past the end answers zero
    /// and raises `overran` rather than trapping; the caller checks it per record.
    struct Bytes {
        let bytes: [UInt8]
        var position = 0
        private(set) var overran = false

        init(_ data: Data) { bytes = [UInt8](data) }

        var count: Int { bytes.count }

        func u8(at offset: Int) -> UInt8 { offset >= 0 && offset < bytes.count ? bytes[offset] : 0 }
        func u16(at offset: Int) -> UInt16 {
            UInt16(u8(at: offset)) | UInt16(u8(at: offset + 1)) << 8
        }
        func u32(at offset: Int) -> UInt32 {
            UInt32(u16(at: offset)) | UInt32(u16(at: offset + 2)) << 16
        }

        mutating func u8() -> UInt8 { u8(at: take(1)) }
        mutating func u16() -> UInt16 { u16(at: take(2)) }
        mutating func s16() -> Int16 { Int16(bitPattern: u16()) }
        mutating func u24() -> UInt32 {
            let at = take(3)
            return UInt32(u8(at: at)) | UInt32(u8(at: at + 1)) << 8 | UInt32(u8(at: at + 2)) << 16
        }
        mutating func s24() -> Int32 {
            let raw = u24()
            return raw & 0x800000 != 0 ? Int32(bitPattern: raw | 0xFF000000) : Int32(raw)
        }
        mutating func u32() -> UInt32 { u32(at: take(4)) }

        /// Steps over `count` bytes and says where they began, for the bit reader.
        mutating func take(_ count: Int) -> Int {
            let at = position
            position += count
            if at < 0 || position > bytes.count { overran = true }
            return at
        }
    }
}
