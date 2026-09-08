import Foundation

/// Streaming MD5, per RFC 1321.
///
/// Used only to verify downloads against the `.md5` files published beside them; it is
/// not a security primitive. Implemented here rather than through CryptoKit so that
/// every platform computes the digest with the same code and no dependency is needed.
struct MD5 {

    /// The four words of state, as RFC 1321 initialises them.
    private var a: UInt32 = 0x6745_2301
    private var b: UInt32 = 0xefcd_ab89
    private var c: UInt32 = 0x98ba_dcfe
    private var d: UInt32 = 0x1032_5476

    /// Bytes seen so far; the padding needs this as a bit count.
    private var length: UInt64 = 0

    /// Bytes left over from the last update, fewer than one 64-byte block.
    private var tail = [UInt8]()

    init() {
        tail.reserveCapacity(blockSize)
    }

    private let blockSize = 64

    // MARK: Feeding it

    mutating func update(_ bytes: UnsafeRawBufferPointer) {
        guard let base = bytes.baseAddress, !bytes.isEmpty else { return }
        length &+= UInt64(bytes.count)
        var offset = 0

        // Finish the partial block first, if there is one.
        if !tail.isEmpty {
            let wanted = min(blockSize - tail.count, bytes.count)
            tail.append(contentsOf: UnsafeRawBufferPointer(start: base, count: wanted))
            offset = wanted
            guard tail.count == blockSize else { return }
            tail.withUnsafeBytes { block in
                if let base = block.baseAddress { absorb(base) }
            }
            tail.removeAll(keepingCapacity: true)
        }

        // Whole blocks are absorbed from the caller's memory without copying.
        while offset + blockSize <= bytes.count {
            absorb(base + offset)
            offset += blockSize
        }

        if offset < bytes.count {
            tail.append(contentsOf: UnsafeRawBufferPointer(start: base + offset,
                                                           count: bytes.count - offset))
        }
    }

    mutating func update(_ data: Data) {
        data.withUnsafeBytes { update($0) }
    }

    mutating func update(_ bytes: [UInt8]) {
        bytes.withUnsafeBytes { update($0) }
    }

    // MARK: Finishing

    /// Returns the sixteen-byte digest. Appends padding, so the hasher must not be fed
    /// again afterwards.
    mutating func finalize() -> [UInt8] {
        let bits = length &* 8

        // A one bit, then zeros to eight bytes short of a block, then the bit count.
        var padding: [UInt8] = [0x80]
        let used = Int(length % UInt64(blockSize))
        let zeros = used < 56 ? 55 - used : 119 - used
        padding.append(contentsOf: [UInt8](repeating: 0, count: zeros))
        withUnsafeBytes(of: bits.littleEndian) { padding.append(contentsOf: $0) }
        // `update` maintains `length`, which the padding must not disturb.
        let real = length
        update(padding)
        length = real

        var digest = [UInt8]()
        digest.reserveCapacity(16)
        for word in [a, b, c, d] {
            withUnsafeBytes(of: word.littleEndian) { digest.append(contentsOf: $0) }
        }
        return digest
    }

    /// Returns the digest as the 32 lowercase hex characters an `.md5` file holds.
    mutating func finalizeHex() -> String {
        MD5.hex(finalize())
    }

    static func hex(_ digest: [UInt8]) -> String {
        // Table lookups rather than a `String(format:)` call per byte.
        let alphabet = Array("0123456789abcdef".utf8)
        var out = [UInt8]()
        out.reserveCapacity(digest.count * 2)
        for byte in digest {
            out.append(alphabet[Int(byte >> 4)])
            out.append(alphabet[Int(byte & 0x0F)])
        }
        return String(decoding: out, as: UTF8.self)
    }

    // MARK: Convenience

    static func hex(of bytes: [UInt8]) -> String {
        var hasher = MD5()
        hasher.update(bytes)
        return hasher.finalizeHex()
    }

    static func hex(of data: Data) -> String {
        var hasher = MD5()
        hasher.update(data)
        return hasher.finalizeHex()
    }

    // MARK: The compression function

    /// Folds one 64-byte block into the state.
    ///
    /// The sixty-four steps are written out with literal constants: table lookups in the
    /// inner loop cost a global access and a bounds check per step. `MD5Tests` checks the
    /// constants against a table derived from `sin`.
    private mutating func absorb(_ block: UnsafeRawPointer) {
        @inline(__always)
        func word(_ index: Int) -> UInt32 {
            UInt32(littleEndian: block.loadUnaligned(fromByteOffset: index * 4, as: UInt32.self))
        }
        @inline(__always)
        func rotated(_ value: UInt32, _ by: UInt32) -> UInt32 {
            (value << by) | (value >> (32 - by))
        }

        // Loaded once, used four times each, and few enough to stay in registers.
        let m00 = word(0), m01 = word(1), m02 = word(2), m03 = word(3)
        let m04 = word(4), m05 = word(5), m06 = word(6), m07 = word(7)
        let m08 = word(8), m09 = word(9), m10 = word(10), m11 = word(11)
        let m12 = word(12), m13 = word(13), m14 = word(14), m15 = word(15)

        var a = self.a, b = self.b, c = self.c, d = self.d

        // Round 1 — F
        a = b &+ rotated(a &+ ((b & c) | (~b & d)) &+ 0xd76aa478 &+ m00, 7)
        d = a &+ rotated(d &+ ((a & b) | (~a & c)) &+ 0xe8c7b756 &+ m01, 12)
        c = d &+ rotated(c &+ ((d & a) | (~d & b)) &+ 0x242070db &+ m02, 17)
        b = c &+ rotated(b &+ ((c & d) | (~c & a)) &+ 0xc1bdceee &+ m03, 22)
        a = b &+ rotated(a &+ ((b & c) | (~b & d)) &+ 0xf57c0faf &+ m04, 7)
        d = a &+ rotated(d &+ ((a & b) | (~a & c)) &+ 0x4787c62a &+ m05, 12)
        c = d &+ rotated(c &+ ((d & a) | (~d & b)) &+ 0xa8304613 &+ m06, 17)
        b = c &+ rotated(b &+ ((c & d) | (~c & a)) &+ 0xfd469501 &+ m07, 22)
        a = b &+ rotated(a &+ ((b & c) | (~b & d)) &+ 0x698098d8 &+ m08, 7)
        d = a &+ rotated(d &+ ((a & b) | (~a & c)) &+ 0x8b44f7af &+ m09, 12)
        c = d &+ rotated(c &+ ((d & a) | (~d & b)) &+ 0xffff5bb1 &+ m10, 17)
        b = c &+ rotated(b &+ ((c & d) | (~c & a)) &+ 0x895cd7be &+ m11, 22)
        a = b &+ rotated(a &+ ((b & c) | (~b & d)) &+ 0x6b901122 &+ m12, 7)
        d = a &+ rotated(d &+ ((a & b) | (~a & c)) &+ 0xfd987193 &+ m13, 12)
        c = d &+ rotated(c &+ ((d & a) | (~d & b)) &+ 0xa679438e &+ m14, 17)
        b = c &+ rotated(b &+ ((c & d) | (~c & a)) &+ 0x49b40821 &+ m15, 22)

        // Round 2 — G
        a = b &+ rotated(a &+ ((b & d) | (c & ~d)) &+ 0xf61e2562 &+ m01, 5)
        d = a &+ rotated(d &+ ((a & c) | (b & ~c)) &+ 0xc040b340 &+ m06, 9)
        c = d &+ rotated(c &+ ((d & b) | (a & ~b)) &+ 0x265e5a51 &+ m11, 14)
        b = c &+ rotated(b &+ ((c & a) | (d & ~a)) &+ 0xe9b6c7aa &+ m00, 20)
        a = b &+ rotated(a &+ ((b & d) | (c & ~d)) &+ 0xd62f105d &+ m05, 5)
        d = a &+ rotated(d &+ ((a & c) | (b & ~c)) &+ 0x02441453 &+ m10, 9)
        c = d &+ rotated(c &+ ((d & b) | (a & ~b)) &+ 0xd8a1e681 &+ m15, 14)
        b = c &+ rotated(b &+ ((c & a) | (d & ~a)) &+ 0xe7d3fbc8 &+ m04, 20)
        a = b &+ rotated(a &+ ((b & d) | (c & ~d)) &+ 0x21e1cde6 &+ m09, 5)
        d = a &+ rotated(d &+ ((a & c) | (b & ~c)) &+ 0xc33707d6 &+ m14, 9)
        c = d &+ rotated(c &+ ((d & b) | (a & ~b)) &+ 0xf4d50d87 &+ m03, 14)
        b = c &+ rotated(b &+ ((c & a) | (d & ~a)) &+ 0x455a14ed &+ m08, 20)
        a = b &+ rotated(a &+ ((b & d) | (c & ~d)) &+ 0xa9e3e905 &+ m13, 5)
        d = a &+ rotated(d &+ ((a & c) | (b & ~c)) &+ 0xfcefa3f8 &+ m02, 9)
        c = d &+ rotated(c &+ ((d & b) | (a & ~b)) &+ 0x676f02d9 &+ m07, 14)
        b = c &+ rotated(b &+ ((c & a) | (d & ~a)) &+ 0x8d2a4c8a &+ m12, 20)

        // Round 3 — H
        a = b &+ rotated(a &+ (b ^ c ^ d) &+ 0xfffa3942 &+ m05, 4)
        d = a &+ rotated(d &+ (a ^ b ^ c) &+ 0x8771f681 &+ m08, 11)
        c = d &+ rotated(c &+ (d ^ a ^ b) &+ 0x6d9d6122 &+ m11, 16)
        b = c &+ rotated(b &+ (c ^ d ^ a) &+ 0xfde5380c &+ m14, 23)
        a = b &+ rotated(a &+ (b ^ c ^ d) &+ 0xa4beea44 &+ m01, 4)
        d = a &+ rotated(d &+ (a ^ b ^ c) &+ 0x4bdecfa9 &+ m04, 11)
        c = d &+ rotated(c &+ (d ^ a ^ b) &+ 0xf6bb4b60 &+ m07, 16)
        b = c &+ rotated(b &+ (c ^ d ^ a) &+ 0xbebfbc70 &+ m10, 23)
        a = b &+ rotated(a &+ (b ^ c ^ d) &+ 0x289b7ec6 &+ m13, 4)
        d = a &+ rotated(d &+ (a ^ b ^ c) &+ 0xeaa127fa &+ m00, 11)
        c = d &+ rotated(c &+ (d ^ a ^ b) &+ 0xd4ef3085 &+ m03, 16)
        b = c &+ rotated(b &+ (c ^ d ^ a) &+ 0x04881d05 &+ m06, 23)
        a = b &+ rotated(a &+ (b ^ c ^ d) &+ 0xd9d4d039 &+ m09, 4)
        d = a &+ rotated(d &+ (a ^ b ^ c) &+ 0xe6db99e5 &+ m12, 11)
        c = d &+ rotated(c &+ (d ^ a ^ b) &+ 0x1fa27cf8 &+ m15, 16)
        b = c &+ rotated(b &+ (c ^ d ^ a) &+ 0xc4ac5665 &+ m02, 23)

        // Round 4 — I
        a = b &+ rotated(a &+ (c ^ (b | ~d)) &+ 0xf4292244 &+ m00, 6)
        d = a &+ rotated(d &+ (b ^ (a | ~c)) &+ 0x432aff97 &+ m07, 10)
        c = d &+ rotated(c &+ (a ^ (d | ~b)) &+ 0xab9423a7 &+ m14, 15)
        b = c &+ rotated(b &+ (d ^ (c | ~a)) &+ 0xfc93a039 &+ m05, 21)
        a = b &+ rotated(a &+ (c ^ (b | ~d)) &+ 0x655b59c3 &+ m12, 6)
        d = a &+ rotated(d &+ (b ^ (a | ~c)) &+ 0x8f0ccc92 &+ m03, 10)
        c = d &+ rotated(c &+ (a ^ (d | ~b)) &+ 0xffeff47d &+ m10, 15)
        b = c &+ rotated(b &+ (d ^ (c | ~a)) &+ 0x85845dd1 &+ m01, 21)
        a = b &+ rotated(a &+ (c ^ (b | ~d)) &+ 0x6fa87e4f &+ m08, 6)
        d = a &+ rotated(d &+ (b ^ (a | ~c)) &+ 0xfe2ce6e0 &+ m15, 10)
        c = d &+ rotated(c &+ (a ^ (d | ~b)) &+ 0xa3014314 &+ m06, 15)
        b = c &+ rotated(b &+ (d ^ (c | ~a)) &+ 0x4e0811a1 &+ m13, 21)
        a = b &+ rotated(a &+ (c ^ (b | ~d)) &+ 0xf7537e82 &+ m04, 6)
        d = a &+ rotated(d &+ (b ^ (a | ~c)) &+ 0xbd3af235 &+ m11, 10)
        c = d &+ rotated(c &+ (a ^ (d | ~b)) &+ 0x2ad7d2bb &+ m02, 15)
        b = c &+ rotated(b &+ (d ^ (c | ~a)) &+ 0xeb86d391 &+ m09, 21)

        self.a &+= a; self.b &+= b; self.c &+= c; self.d &+= d
    }
}
