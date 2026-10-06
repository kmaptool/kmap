import Foundation

/// A block's strings, interned as it is built. Index 0 is reserved and always empty; an
/// empty text asked for is given an index of its own, as any other is.
///
/// Its own table rather than a dictionary of strings: every tag of every element is
/// looked up here, and hashing a string the standard way first normalises it. A key or
/// value is nearly always ASCII, which hashes by its bytes; anything else hashes as the
/// standard library has it, so 2 spellings of the same text still meet. A text that is
/// ASCII but for `asciiTwins` equals an ASCII text, and hashes as that one.
struct StringTable {
    private(set) var words: [String] = [""]
    /// Open addressing: the index into `words`, or 0 for a free slot. A power of 2 long.
    private var slots = [Int32](repeating: 0, count: 256)
    private var hashes: [UInt64] = [0]

    mutating func index(_ word: String) -> Int32 {
        let hash = Self.hash(word)
        var at = Int(truncatingIfNeeded: hash) & (slots.count - 1)
        while true {
            let held = slots[at]
            if held == 0 { break }
            if hashes[Int(held)] == hash, words[Int(held)] == word { return held }
            at = (at + 1) & (slots.count - 1)
        }
        words.append(word)
        hashes.append(hash)
        let made = Int32(words.count - 1)
        slots[at] = made
        if words.count * 2 > slots.count { grow() }
        return made
    }

    private mutating func grow() {
        slots = [Int32](repeating: 0, count: slots.count * 2)
        for index in 1..<words.count {
            var at = Int(truncatingIfNeeded: hashes[index]) & (slots.count - 1)
            while slots[at] != 0 { at = (at + 1) & (slots.count - 1) }
            slots[at] = Int32(index)
        }
    }

    /// The only scalars past ASCII that the standard library holds equal to an ASCII
    /// character: Greek question mark, Greek varia, Kelvin sign. Each is its character
    /// in canonical form, so "K" and "\u{212A}" are 1 word.
    static let asciiTwins: [UInt32: UInt8] = [0x037E: 0x3B, 0x1FEF: 0x60, 0x212A: 0x4B]

    /// A hash of the bytes of an ASCII string, or of the ASCII text a string equals; the
    /// standard hash for any other, which is equal for texts the standard library holds
    /// equal.
    private static func hash(_ word: String) -> UInt64 {
        var word = word
        let quick: UInt64? = word.withUTF8 { bytes in
            let (hash, high) = mix(bytes)
            return high & 0x8080_8080_8080_8080 == 0 ? hash : nil
        }
        if let quick { return quick }
        guard word.unicodeScalars.allSatisfy({ $0.isASCII || asciiTwins[$0.value] != nil }) else {
            return UInt64(truncatingIfNeeded: word.hashValue)
        }
        let ascii = word.unicodeScalars.map { $0.isASCII ? UInt8($0.value) : asciiTwins[$0.value] ?? 0 }
        return ascii.withUnsafeBufferPointer { mix($0).hash }
    }

    /// 8 bytes at a time rather than 1, so a word waits on 1 multiply instead of 8. A
    /// length not a multiple of 8 ends on a word overlapping the one before, so the length
    /// goes in first. Answers the hash and every byte or-ed together.
    @inline(__always)
    private static func mix(_ bytes: UnsafeBufferPointer<UInt8>) -> (hash: UInt64, high: UInt64) {
        let count = bytes.count
        var hash = seed ^ (UInt64(count) &* multiplier)
        var high: UInt64 = 0
        guard let base = bytes.baseAddress, count > 0 else { return (finish(hash), 0) }
        let raw = UnsafeRawPointer(base)
        func step(_ word: UInt64) {
            high |= word
            hash = (hash ^ word) &* multiplier
            hash ^= hash >> 32
        }
        if count >= 8 {
            var at = 0
            while at + 8 < count {
                step(raw.loadUnaligned(fromByteOffset: at, as: UInt64.self))
                at += 8
            }
            step(raw.loadUnaligned(fromByteOffset: count - 8, as: UInt64.self))
        } else if count >= 4 {
            let low = UInt64(raw.loadUnaligned(fromByteOffset: 0, as: UInt32.self))
            let top = UInt64(raw.loadUnaligned(fromByteOffset: count - 4, as: UInt32.self))
            step(low | top << 32)
        } else {
            step(UInt64(base[0]) | UInt64(base[count / 2]) << 8 | UInt64(base[count - 1]) << 16)
        }
        return (finish(hash), high)
    }

    /// Spreads the high bits into the low ones, which pick the slot.
    @inline(__always)
    private static func finish(_ hash: UInt64) -> UInt64 {
        var hash = hash
        hash ^= hash >> 33
        hash = hash &* 0xff51_afd7_ed55_8ccd
        return hash ^ hash >> 29
    }

    private static let seed: UInt64 = 0xcbf2_9ce4_8422_2325
    private static let multiplier: UInt64 = 0x9e37_79b9_7f4a_7c15
}
