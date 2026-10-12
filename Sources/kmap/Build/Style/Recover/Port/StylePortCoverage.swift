import Foundation

extension StylePort {
    /// Our numbers for the meanings their map leaves to the receiver: drawn with a
    /// number their TYP has no section for at all, so the receiver's own glyph is what
    /// their map shows. A bay's name, a town. Declared in the ported TYP, so the build
    /// does not silence the rule for want of a picture.
    static func leftToTheDevice(
        codesByTag: [String: [String: Int]],
        rules: RuleSetIndex,
        theirTyp: TypSource,
        ported: [Ported]
    ) -> [MapElementKind: Set<Int>] {
        let ourCodes = ourNumbers(in: rules)
        var painted: [MapElementKind: Set<Int>] = [:]
        for port in ported { painted[port.kind, default: []].insert(port.ours) }
        var out: [MapElementKind: Set<Int>] = [:]
        for (tag, drawn) in codesByTag {
            for (key, count) in drawn where count >= fewestToPort {
                guard let (kind, code) = read(key), theirTyp.section(kind, code) == nil,
                    let ours = ourCodes[kind]?[tag]
                else { continue }
                for number in ours where painted[kind]?.contains(number) != true {
                    out[kind, default: []].insert(number)
                }
            }
        }
        return out
    }

    /// What their style draws that no number of ours can carry: the list that says
    /// where kmap's own rules want widening.
    static func uncovered(
        codesByTag: [String: [String: Int]],
        rules: RuleSetIndex,
        theirs: TypSource,
        ported: [Ported]
    ) -> [Ported] {
        // The ground's pictures are drawn too, from the sections of theirs it takes.
        let taken = Set(
            ported.map { "\($0.kind.rawValue):\($0.theirs)" }
                + generatedTypes.map { "\($0.kind.rawValue):\($0.theirs)" }
        )
        var out: [String: Ported] = [:]
        // In the meanings' own order: a picture drawn as much for two of them would
        // otherwise be reported under whichever the dictionary handed over first.
        for tag in codesByTag.keys.sorted() {
            for (key, count) in codesByTag[tag] ?? [:] {
                guard let (kind, code) = read(key),
                    !taken.contains("\(kind.rawValue):\(code)"),
                    draws(theirs.section(kind, code))
                else { continue }
                let held = out["\(kind.rawValue):\(code)"]
                if held == nil || count > held!.witnesses {
                    out["\(kind.rawValue):\(code)"] = Ported(
                        ours: 0,
                        theirs: code,
                        kind: kind,
                        meaning: tag,
                        witnesses: count,
                        width: nil
                    )
                }
            }
        }
        return out.values.sorted {
            ($0.witnesses, $1.kind.rawValue, $1.theirs)
                > ($1.witnesses, $0.kind.rawValue, $0.theirs)
        }
    }

    /// Whether a section draws anything: an all-transparent pattern is a number kept
    /// for routing and left to the device.
    static func draws(_ section: TypSection?) -> Bool {
        guard let section else { return false }
        let blocks = [section.xpm, section.dayXpm].compactMap { $0 }
        guard !blocks.isEmpty else { return false }
        return blocks.contains { block in
            // Colours only: a fill, and it draws whatever the palette says.
            guard !block.isSolid else { return block.colours.contains { $0 != nil } }
            // A pattern draws only where a pixel names an opaque colour.
            let opaque = Set(block.palette.filter { $0.colour != nil }.map(\.key))
            guard !opaque.isEmpty else { return false }
            return block.rows.contains { row in
                stride(from: 0, to: row.count, by: max(1, block.charsPerPixel)).contains {
                    at in
                    let start = row.index(row.startIndex, offsetBy: at)
                    let end =
                        row.index(
                            start,
                            offsetBy: max(1, block.charsPerPixel),
                            limitedBy: row.endIndex
                        ) ?? row.endIndex
                    return opaque.contains(String(row[start..<end]))
                }
            }
        }
    }
}
