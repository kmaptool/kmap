import Foundation

/// Streaming SHA-256, per FIPS 180-4.
///
/// Used to check a downloaded archive against the digest its publisher states before
/// anything inside it is unpacked or run. Implemented here rather than through CryptoKit
/// so that every platform computes the digest with the same code and no dependency is
/// needed.
struct SHA256 {
    /// The eight words of state: the first thirty-two bits of the fractional parts of the
    /// square roots of the first eight primes.
    private var h: (UInt32, UInt32, UInt32, UInt32, UInt32, UInt32, UInt32, UInt32) =
        (
            0x6a09_e667, 0xbb67_ae85, 0x3c6e_f372, 0xa54f_f53a,
            0x510e_527f, 0x9b05_688c, 0x1f83_d9ab, 0x5be0_cd19
        )

    /// Bytes seen so far; the padding needs this as a bit count.
    private var length: UInt64 = 0

    /// Bytes left over from the last update, fewer than one 64-byte block.
    private var tail = [UInt8]()

    private let blockSize = 64

    init() {
        tail.reserveCapacity(blockSize)
    }

    /// The round constants: the first thirty-two bits of the fractional parts of the cube
    /// roots of the first sixty-four primes. `SHA256Tests` derives them again and compares.
    private static let k: [UInt32] = [
        0x428a_2f98, 0x7137_4491, 0xb5c0_fbcf, 0xe9b5_dba5,
        0x3956_c25b, 0x59f1_11f1, 0x923f_82a4, 0xab1c_5ed5,
        0xd807_aa98, 0x1283_5b01, 0x2431_85be, 0x550c_7dc3,
        0x72be_5d74, 0x80de_b1fe, 0x9bdc_06a7, 0xc19b_f174,
        0xe49b_69c1, 0xefbe_4786, 0x0fc1_9dc6, 0x240c_a1cc,
        0x2de9_2c6f, 0x4a74_84aa, 0x5cb0_a9dc, 0x76f9_88da,
        0x983e_5152, 0xa831_c66d, 0xb003_27c8, 0xbf59_7fc7,
        0xc6e0_0bf3, 0xd5a7_9147, 0x06ca_6351, 0x1429_2967,
        0x27b7_0a85, 0x2e1b_2138, 0x4d2c_6dfc, 0x5338_0d13,
        0x650a_7354, 0x766a_0abb, 0x81c2_c92e, 0x9272_2c85,
        0xa2bf_e8a1, 0xa81a_664b, 0xc24b_8b70, 0xc76c_51a3,
        0xd192_e819, 0xd699_0624, 0xf40e_3585, 0x106a_a070,
        0x19a4_c116, 0x1e37_6c08, 0x2748_774c, 0x34b0_bcb5,
        0x391c_0cb3, 0x4ed8_aa4a, 0x5b9c_ca4f, 0x682e_6ff3,
        0x748f_82ee, 0x78a5_636f, 0x84c8_7814, 0x8cc7_0208,
        0x90be_fffa, 0xa450_6ceb, 0xbef9_a3f7, 0xc671_78f2
    ]

    /// One round constant, for the test that derives them again from the primes.
    static func constant(_ index: Int) -> UInt32 { k[index] }

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
            tail.append(
                contentsOf: UnsafeRawBufferPointer(
                    start: base + offset,
                    count: bytes.count - offset
                )
            )
        }
    }

    mutating func update(_ data: Data) {
        data.withUnsafeBytes { update($0) }
    }

    mutating func update(_ bytes: [UInt8]) {
        bytes.withUnsafeBytes { update($0) }
    }

    // MARK: Finishing

    /// Returns the thirty-two-byte digest. Appends padding, so the hasher must not be fed
    /// again afterwards.
    mutating func finalize() -> [UInt8] {
        let bits = length &* 8

        // A one bit, then zeros to eight bytes short of a block, then the bit count.
        var padding: [UInt8] = [0x80]
        let used = Int(length % UInt64(blockSize))
        let zeros = used < 56 ? 55 - used : 119 - used
        padding.append(contentsOf: [UInt8](repeating: 0, count: zeros))
        withUnsafeBytes(of: bits.bigEndian) { padding.append(contentsOf: $0) }
        // `update` maintains `length`, which the padding must not disturb.
        let real = length
        update(padding)
        length = real

        var digest = [UInt8]()
        digest.reserveCapacity(32)
        for word in [h.0, h.1, h.2, h.3, h.4, h.5, h.6, h.7] {
            withUnsafeBytes(of: word.bigEndian) { digest.append(contentsOf: $0) }
        }
        return digest
    }

    /// Returns the digest as the 64 lowercase hex characters a checksum is published as.
    mutating func finalizeHex() -> String {
        SHA256.hex(finalize())
    }

    static func hex(_ digest: [UInt8]) -> String {
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
        var hasher = SHA256()
        hasher.update(bytes)
        return hasher.finalizeHex()
    }

    static func hex(of data: Data) -> String {
        var hasher = SHA256()
        hasher.update(data)
        return hasher.finalizeHex()
    }

    /// The digest of a file, read in chunks so a 200 MB archive is not held in memory.
    ///
    /// - Returns: nil where the file cannot be read.
    static func hex(ofFileAt url: URL, chunk: Int = 1 << 20) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            guard let data = try? handle.read(upToCount: chunk), !data.isEmpty else { break }
            hasher.update(data)
        }
        return hasher.finalizeHex()
    }

    // MARK: The compression function

    /// Folds one 64-byte block into the state.
    ///
    /// The 64 rounds are written out, each naming 8 working words in the order that
    /// round sees them, so no word is moved between rounds; the schedule is 16 words
    /// kept in registers and renewed in place. The constants are read from `k`, which
    /// the tests derive again.
    private mutating func absorb(_ block: UnsafeRawPointer) {
        @inline(__always)
        func word(_ index: Int) -> UInt32 {
            UInt32(bigEndian: block.loadUnaligned(fromByteOffset: index * 4, as: UInt32.self))
        }
        @inline(__always)
        func rotated(_ value: UInt32, _ by: UInt32) -> UInt32 {
            (value >> by) | (value << (32 - by))
        }
        /// The next word of the schedule, from the word 16 back and 3 others.
        @inline(__always)
        func mixed(_ w0: UInt32, _ w1: UInt32, _ w9: UInt32, _ w14: UInt32) -> UInt32 {
            let s0 = rotated(w1, 7) ^ rotated(w1, 18) ^ (w1 >> 3)
            let s1 = rotated(w14, 17) ^ rotated(w14, 19) ^ (w14 >> 10)
            return w0 &+ s0 &+ w9 &+ s1
        }
        /// A round. Only `d` and `h` change; the caller turns the names instead.
        @inline(__always)
        func round(
            _ a: UInt32,
            _ b: UInt32,
            _ c: UInt32,
            _ d: inout UInt32,
            _ e: UInt32,
            _ f: UInt32,
            _ g: UInt32,
            _ h: inout UInt32,
            _ k: UInt32,
            _ w: UInt32
        ) {
            let s1 = rotated(e, 6) ^ rotated(e, 11) ^ rotated(e, 25)
            let choice = g ^ (e & (f ^ g))
            // The constant and the word first: neither waits on the round before.
            let temp1 = (k &+ w &+ h) &+ choice &+ s1
            let s0 = rotated(a, 2) ^ rotated(a, 13) ^ rotated(a, 22)
            let majority = (a & b) | (c & (a | b))
            d &+= temp1
            h = temp1 &+ s0 &+ majority
        }

        var w00 = word(0), w01 = word(1), w02 = word(2), w03 = word(3)
        var w04 = word(4), w05 = word(5), w06 = word(6), w07 = word(7)
        var w08 = word(8), w09 = word(9), w10 = word(10), w11 = word(11)
        var w12 = word(12), w13 = word(13), w14 = word(14), w15 = word(15)

        var a = h.0, b = h.1, c = h.2, d = h.3
        var e = h.4, f = h.5, g = h.6, hh = h.7

        SHA256.k.withUnsafeBufferPointer { k in
            round(a, b, c, &d, e, f, g, &hh, k[0], w00)
            round(hh, a, b, &c, d, e, f, &g, k[1], w01)
            round(g, hh, a, &b, c, d, e, &f, k[2], w02)
            round(f, g, hh, &a, b, c, d, &e, k[3], w03)
            round(e, f, g, &hh, a, b, c, &d, k[4], w04)
            round(d, e, f, &g, hh, a, b, &c, k[5], w05)
            round(c, d, e, &f, g, hh, a, &b, k[6], w06)
            round(b, c, d, &e, f, g, hh, &a, k[7], w07)
            round(a, b, c, &d, e, f, g, &hh, k[8], w08)
            round(hh, a, b, &c, d, e, f, &g, k[9], w09)
            round(g, hh, a, &b, c, d, e, &f, k[10], w10)
            round(f, g, hh, &a, b, c, d, &e, k[11], w11)
            round(e, f, g, &hh, a, b, c, &d, k[12], w12)
            round(d, e, f, &g, hh, a, b, &c, k[13], w13)
            round(c, d, e, &f, g, hh, a, &b, k[14], w14)
            round(b, c, d, &e, f, g, hh, &a, k[15], w15)

            w00 = mixed(w00, w01, w09, w14)
            round(a, b, c, &d, e, f, g, &hh, k[16], w00)
            w01 = mixed(w01, w02, w10, w15)
            round(hh, a, b, &c, d, e, f, &g, k[17], w01)
            w02 = mixed(w02, w03, w11, w00)
            round(g, hh, a, &b, c, d, e, &f, k[18], w02)
            w03 = mixed(w03, w04, w12, w01)
            round(f, g, hh, &a, b, c, d, &e, k[19], w03)
            w04 = mixed(w04, w05, w13, w02)
            round(e, f, g, &hh, a, b, c, &d, k[20], w04)
            w05 = mixed(w05, w06, w14, w03)
            round(d, e, f, &g, hh, a, b, &c, k[21], w05)
            w06 = mixed(w06, w07, w15, w04)
            round(c, d, e, &f, g, hh, a, &b, k[22], w06)
            w07 = mixed(w07, w08, w00, w05)
            round(b, c, d, &e, f, g, hh, &a, k[23], w07)
            w08 = mixed(w08, w09, w01, w06)
            round(a, b, c, &d, e, f, g, &hh, k[24], w08)
            w09 = mixed(w09, w10, w02, w07)
            round(hh, a, b, &c, d, e, f, &g, k[25], w09)
            w10 = mixed(w10, w11, w03, w08)
            round(g, hh, a, &b, c, d, e, &f, k[26], w10)
            w11 = mixed(w11, w12, w04, w09)
            round(f, g, hh, &a, b, c, d, &e, k[27], w11)
            w12 = mixed(w12, w13, w05, w10)
            round(e, f, g, &hh, a, b, c, &d, k[28], w12)
            w13 = mixed(w13, w14, w06, w11)
            round(d, e, f, &g, hh, a, b, &c, k[29], w13)
            w14 = mixed(w14, w15, w07, w12)
            round(c, d, e, &f, g, hh, a, &b, k[30], w14)
            w15 = mixed(w15, w00, w08, w13)
            round(b, c, d, &e, f, g, hh, &a, k[31], w15)

            w00 = mixed(w00, w01, w09, w14)
            round(a, b, c, &d, e, f, g, &hh, k[32], w00)
            w01 = mixed(w01, w02, w10, w15)
            round(hh, a, b, &c, d, e, f, &g, k[33], w01)
            w02 = mixed(w02, w03, w11, w00)
            round(g, hh, a, &b, c, d, e, &f, k[34], w02)
            w03 = mixed(w03, w04, w12, w01)
            round(f, g, hh, &a, b, c, d, &e, k[35], w03)
            w04 = mixed(w04, w05, w13, w02)
            round(e, f, g, &hh, a, b, c, &d, k[36], w04)
            w05 = mixed(w05, w06, w14, w03)
            round(d, e, f, &g, hh, a, b, &c, k[37], w05)
            w06 = mixed(w06, w07, w15, w04)
            round(c, d, e, &f, g, hh, a, &b, k[38], w06)
            w07 = mixed(w07, w08, w00, w05)
            round(b, c, d, &e, f, g, hh, &a, k[39], w07)
            w08 = mixed(w08, w09, w01, w06)
            round(a, b, c, &d, e, f, g, &hh, k[40], w08)
            w09 = mixed(w09, w10, w02, w07)
            round(hh, a, b, &c, d, e, f, &g, k[41], w09)
            w10 = mixed(w10, w11, w03, w08)
            round(g, hh, a, &b, c, d, e, &f, k[42], w10)
            w11 = mixed(w11, w12, w04, w09)
            round(f, g, hh, &a, b, c, d, &e, k[43], w11)
            w12 = mixed(w12, w13, w05, w10)
            round(e, f, g, &hh, a, b, c, &d, k[44], w12)
            w13 = mixed(w13, w14, w06, w11)
            round(d, e, f, &g, hh, a, b, &c, k[45], w13)
            w14 = mixed(w14, w15, w07, w12)
            round(c, d, e, &f, g, hh, a, &b, k[46], w14)
            w15 = mixed(w15, w00, w08, w13)
            round(b, c, d, &e, f, g, hh, &a, k[47], w15)

            w00 = mixed(w00, w01, w09, w14)
            round(a, b, c, &d, e, f, g, &hh, k[48], w00)
            w01 = mixed(w01, w02, w10, w15)
            round(hh, a, b, &c, d, e, f, &g, k[49], w01)
            w02 = mixed(w02, w03, w11, w00)
            round(g, hh, a, &b, c, d, e, &f, k[50], w02)
            w03 = mixed(w03, w04, w12, w01)
            round(f, g, hh, &a, b, c, d, &e, k[51], w03)
            w04 = mixed(w04, w05, w13, w02)
            round(e, f, g, &hh, a, b, c, &d, k[52], w04)
            w05 = mixed(w05, w06, w14, w03)
            round(d, e, f, &g, hh, a, b, &c, k[53], w05)
            w06 = mixed(w06, w07, w15, w04)
            round(c, d, e, &f, g, hh, a, &b, k[54], w06)
            w07 = mixed(w07, w08, w00, w05)
            round(b, c, d, &e, f, g, hh, &a, k[55], w07)
            w08 = mixed(w08, w09, w01, w06)
            round(a, b, c, &d, e, f, g, &hh, k[56], w08)
            w09 = mixed(w09, w10, w02, w07)
            round(hh, a, b, &c, d, e, f, &g, k[57], w09)
            w10 = mixed(w10, w11, w03, w08)
            round(g, hh, a, &b, c, d, e, &f, k[58], w10)
            w11 = mixed(w11, w12, w04, w09)
            round(f, g, hh, &a, b, c, d, &e, k[59], w11)
            w12 = mixed(w12, w13, w05, w10)
            round(e, f, g, &hh, a, b, c, &d, k[60], w12)
            w13 = mixed(w13, w14, w06, w11)
            round(d, e, f, &g, hh, a, b, &c, k[61], w13)
            w14 = mixed(w14, w15, w07, w12)
            round(c, d, e, &f, g, hh, a, &b, k[62], w14)
            w15 = mixed(w15, w00, w08, w13)
            round(b, c, d, &e, f, g, hh, &a, k[63], w15)
        }

        h = (
            h.0 &+ a, h.1 &+ b, h.2 &+ c, h.3 &+ d,
            h.4 &+ e, h.5 &+ f, h.6 &+ g, h.7 &+ hh
        )
    }
}
