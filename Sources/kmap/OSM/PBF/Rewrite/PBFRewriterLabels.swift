import Foundation

/// Characters no Garmin code page has, taken out of the text a label is made from: a
/// stress mark over a Russian vowel and an emoji both come out as "?" on the device.
extension PBFRewriter {
    /// The keys a label or a card is made from.
    private static let labelKeys = [
        "name", "int_name", "alt_name", "old_name", "official_name", "short_name", "description", "brand", "operator"
    ]

    /// Whether `text` holds any of them. On the UTF-8 bytes: 0xCC leads the combining
    /// accents, 0xE2 the zero-width marks and the symbols, 0xEF 0xBB the byte-order mark,
    /// 0xF0 the emoji, 0xF3 their tag characters; a Cyrillic letter leads with 0xD0 or 0xD1.
    static func hasUnprintable(_ text: String) -> Bool {
        var utf8 = text.utf8.makeIterator()
        while let byte = utf8.next() {
            switch byte {
            case 0xCC, 0xF0, 0xF3: return true
            case 0xE2, 0xEF:
                return text.unicodeScalars.contains(where: unprintable)
            default: continue
            }
        }
        return false
    }

    private static func unprintable(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        // Stress marks, zero-width space, non-joiner and joiner, symbols and dingbats (a
        // heart), the keycap, emoji and their tag characters.
        case 0x0300, 0x0301, 0x200B...0x200D, 0xFEFF, 0x20E3, 0x2600...0x27BF, 0x2B00...0x2BFF,
            0x1F000...0x1FAFF, 0xE0020...0xE007F:
            return true
        default: return false
        }
    }

    private static func isJoiner(_ scalar: Unicode.Scalar) -> Bool {
        scalar.value == 0x200C || scalar.value == 0x200D
    }

    /// Drops them from the label keys, and a space they leave doubled. The zero-width
    /// joiner and non-joiner stay where `keepingJoiners`: Persian spells with them, and
    /// only the Arabic page has them; any other page draws them as "?".
    static func clean(_ tags: inout [(String, String)], keepingJoiners: Bool = false) {
        for i in tags.indices where labelKeys.contains(where: { tags[i].0 == $0 || tags[i].0.hasPrefix($0 + ":") }) {
            let value = tags[i].1
            guard hasUnprintable(value) else { continue }
            // Composed first: a letter written as 2 code points, a Russian short i as i and
            // a breve, becomes the 1 a code page has, and only a mark left over is dropped.
            let kept = Array(
                value.precomposedStringWithCanonicalMapping.unicodeScalars.filter {
                    (!unprintable($0) || (keepingJoiners && isJoiner($0))) && $0.value != 0xFE0F
                }
            )
            // A joiner stays only between 2 letters: one an emoji held together is not one.
            var scalars = String.UnicodeScalarView()
            for (at, scalar) in kept.enumerated()
            where !isJoiner(scalar)
                || (at > 0 && at + 1 < kept.count && kept[at - 1].properties.isAlphabetic
                    && kept[at + 1].properties.isAlphabetic)
            {
                scalars.append(scalar)
            }
            tags[i].1 = String(scalars).split(separator: " ", omittingEmptySubsequences: true).joined(separator: " ")
        }
    }
}
