import Foundation

extension TypAugment {
    /// The sections a build's copy gains: the repair marks the style lacks, on the numbers
    /// they were moved to, and the copies of open ground.
    static func additions(
        wanted: [(kind: MapElementKind, code: Int, what: String)],
        moved: [MapElementKind: [Int: Int]],
        copies: [(code: Int, text: String)],
        byteForByte: Bool
    ) -> [(code: Int, text: String)] {
        var additions = sections(of: StyleAssets.repairMarks)
            .filter { section in
                wanted.contains { $0.code == section.code }
                    || moved.values.contains { $0[section.code] != nil }
            }
        additions.append(contentsOf: copies)
        // Such a page holds no Cyrillic: a mark's label in it is left out, not the file
        // turned to UTF-8 under the style's own labels.
        if byteForByte {
            additions = additions.map { section in
                let kept = section.text.components(separatedBy: "\n").filter { line in
                    line.unicodeScalars.allSatisfy { $0.value <= 0xFF }
                }
                return (code: section.code, text: kept.joined(separator: "\n"))
            }
        }
        // A moved mark is the same drawing under another number.
        additions = additions.map { section in
            guard let to = moved.values.compactMap({ $0[section.code] }).first
            else { return section }
            return (
                code: to,
                text: section.text.replacingOccurrences(
                    of: String(format: "Type=0x%02x", section.code),
                    with: String(format: "Type=0x%02x", to)
                )
            )
        }
        return additions
    }
}
