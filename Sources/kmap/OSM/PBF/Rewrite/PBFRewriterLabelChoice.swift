import Foundation

/// A name the code page cannot draw swapped for one it can. mkgmap takes the first name
/// tag present, readable or not; that tag gets the value of the first that reads: the next
/// in its order, then `int_name`, then `name:en`.
extension PBFRewriter {
    /// Whether the map's readers read `text` as it stands: no letter or mark in it is one
    /// MkgmapUnreadable lists for the page. Symbols are not judged: a "?" for a currency sign
    /// is no reason to give up the name. A page with no table reads all: it is chosen for its
    /// own script.
    static func reads(_ text: String, codePage: Int) -> Bool {
        guard let unreadable = MkgmapUnreadable.pages[codePage], !readsAtSight(text, codePage: codePage) else {
            return true
        }
        return readsLetterByLetter(text, unreadable: unreadable)
    }

    /// `reads` without its look at the bytes.
    static func readsLetterByLetter(_ text: String, codePage: Int) -> Bool {
        guard let unreadable = MkgmapUnreadable.pages[codePage] else { return true }
        return readsLetterByLetter(text, unreadable: unreadable)
    }

    /// Composed first, as mkgmap labels it: a letter and its mark as one where Unicode has it.
    private static func readsLetterByLetter(_ text: String, unreadable: [ClosedRange<UInt16>]) -> Bool {
        text.precomposedStringWithCanonicalMapping.unicodeScalars.allSatisfy { scalar in
            !isJudged(scalar) || (scalar.value <= 0xFFFF && !isListed(UInt16(scalar.value), in: unreadable))
        }
    }

    /// Letters and marks, as the table was made.
    private static func isJudged(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.properties.generalCategory {
        case .nonspacingMark, .spacingMark, .enclosingMark: return true
        default: return scalar.properties.isAlphabetic
        }
    }

    /// The bytes alone, for the names nearly all are: ASCII, Latin up to U+017F, dashes and
    /// quotes, and on the Cyrillic page its letters up to U+047F. False only says to look
    /// closer.
    private static func readsAtSight(_ text: String, codePage: Int) -> Bool {
        let cyrillic = codePage == CodePage.cyrillic
        var utf8 = text.utf8.makeIterator()
        while let byte = utf8.next() {
            switch byte {
            case 0x00...0x7F: continue
            // U+0080 to U+017F; on the Cyrillic page U+0400 to U+047F.
            case 0xC2...0xC5: _ = utf8.next()
            case 0xD0...0xD1 where cyrillic: _ = utf8.next()
            // U+2000 to U+203F: dashes, quotes and the like, no letters.
            case 0xE2:
                guard utf8.next() == 0x80 else { return false }
                _ = utf8.next()
            default: return false
            }
        }
        return true
    }

    private static func isListed(_ value: UInt16, in ranges: [ClosedRange<UInt16>]) -> Bool {
        var low = 0
        var high = ranges.count
        while low < high {
            let middle = (low + high) / 2
            if ranges[middle].upperBound < value { low = middle + 1 } else { high = middle }
        }
        return low < ranges.count && ranges[low].contains(value)
    }

    /// Where in `tags` mkgmap takes its name from `order`, and the first value that reads
    /// to put there; nil where it reads already or nothing does. A tag with an empty value
    /// is none: mkgmap drops it as it reads the data.
    static func readableName(
        for tags: [(String, String)],
        order: [String],
        codePage: Int
    ) -> (at: Int, value: String)? {
        guard let taken = order.firstIndex(where: { key in tags.contains { $0.0 == key && !$0.1.isEmpty } }),
            let at = tags.firstIndex(where: { $0.0 == order[taken] && !$0.1.isEmpty }),
            !reads(tags[at].1, codePage: codePage)
        else { return nil }
        var others = Array(order[(taken + 1)...])
        for key in ["int_name", "name:en"] where !others.contains(key) && key != order[taken] { others.append(key) }
        for key in others {
            if let value = tags.first(where: { $0.0 == key && !$0.1.isEmpty })?.1, reads(value, codePage: codePage) {
                return (at, value)
            }
        }
        return nil
    }

    /// Puts `readableName` in place. Returns whether it did.
    static func chooseReadableName(_ tags: inout [(String, String)], order: [String], codePage: Int) -> Bool {
        guard let found = readableName(for: tags, order: order, codePage: codePage) else { return false }
        tags[found.at].1 = found.value
        return true
    }
}
