import Foundation

/// A block's strings, interned as it is built. Index 0 is reserved and always empty; an
/// empty text asked for is given an index of its own, as any other is.
///
/// Its own table rather than a dictionary of strings: every tag of every element is
/// looked up here, and hashing a string the standard way first normalises it. A key or
/// value is nearly always ASCII, which hashes by its bytes; anything else hashes as the
/// standard library has it, so 2 spellings of the same text still meet.
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

    /// FNV-1a over the bytes of an ASCII string; the standard hash for any other, which
    /// is equal for texts the standard library holds equal.
    private static func hash(_ word: String) -> UInt64 {
        var word = word
        let quick: UInt64? = word.withUTF8 { bytes in
            var hash: UInt64 = 0xcbf2_9ce4_8422_2325
            var high: UInt8 = 0
            for byte in bytes {
                hash = (hash ^ UInt64(byte)) &* 0x0000_0100_0000_01b3
                high |= byte
            }
            return high < 0x80 ? hash : nil
        }
        return quick ?? UInt64(truncatingIfNeeded: word.hashValue)
    }
}
