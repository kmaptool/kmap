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
        (0x6a09_e667, 0xbb67_ae85, 0x3c6e_f372, 0xa54f_f53a,
         0x510e_527f, 0x9b05_688c, 0x1f83_d9ab, 0x5be0_cd19)

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
        0x90be_fffa, 0xa450_6ceb, 0xbef9_a3f7, 0xc671_78f2,
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
    private mutating func absorb(_ block: UnsafeRawPointer) {
        @inline(__always)
        func rotated(_ value: UInt32, _ by: UInt32) -> UInt32 {
            (value >> by) | (value << (32 - by))
        }

        // The message schedule: sixteen words from the block, then forty-eight derived.
        var w = [UInt32](repeating: 0, count: 64)
        for i in 0..<16 {
            w[i] = UInt32(bigEndian: block.loadUnaligned(fromByteOffset: i * 4,
                                                          as: UInt32.self))
        }
        for i in 16..<64 {
            let s0 = rotated(w[i - 15], 7) ^ rotated(w[i - 15], 18) ^ (w[i - 15] >> 3)
            let s1 = rotated(w[i - 2], 17) ^ rotated(w[i - 2], 19) ^ (w[i - 2] >> 10)
            w[i] = w[i - 16] &+ s0 &+ w[i - 7] &+ s1
        }

        var a = h.0, b = h.1, c = h.2, d = h.3
        var e = h.4, f = h.5, g = h.6, hh = h.7

        for i in 0..<64 {
            let s1 = rotated(e, 6) ^ rotated(e, 11) ^ rotated(e, 25)
            let choice = (e & f) ^ (~e & g)
            let temp1 = hh &+ s1 &+ choice &+ SHA256.k[i] &+ w[i]
            let s0 = rotated(a, 2) ^ rotated(a, 13) ^ rotated(a, 22)
            let majority = (a & b) ^ (a & c) ^ (b & c)
            let temp2 = s0 &+ majority

            hh = g; g = f; f = e
            e = d &+ temp1
            d = c; c = b; b = a
            a = temp1 &+ temp2
        }

        h = (h.0 &+ a, h.1 &+ b, h.2 &+ c, h.3 &+ d,
             h.4 &+ e, h.5 &+ f, h.6 &+ g, h.7 &+ hh)
    }
}
