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

    /// FNV-1a over the bytes of an ASCII string, or of the ASCII text a string equals; the
    /// standard hash for any other, which is equal for texts the standard library holds
    /// equal.
    private static func hash(_ word: String) -> UInt64 {
        var word = word
        let quick: UInt64? = word.withUTF8 { bytes in
            var hash = fnvBasis
            var high: UInt8 = 0
            for byte in bytes {
                hash = (hash ^ UInt64(byte)) &* fnvPrime
                high |= byte
            }
            return high < 0x80 ? hash : nil
        }
        if let quick { return quick }
        var hash = fnvBasis
        for scalar in word.unicodeScalars {
            let byte: UInt8
            if scalar.isASCII {
                byte = UInt8(scalar.value)
            } else if let twin = asciiTwins[scalar.value] {
                byte = twin
            } else {
                return UInt64(truncatingIfNeeded: word.hashValue)
            }
            hash = (hash ^ UInt64(byte)) &* fnvPrime
        }
        return hash
    }

    private static let fnvBasis: UInt64 = 0xcbf2_9ce4_8422_2325
    private static let fnvPrime: UInt64 = 0x0000_0100_0000_01b3
}
