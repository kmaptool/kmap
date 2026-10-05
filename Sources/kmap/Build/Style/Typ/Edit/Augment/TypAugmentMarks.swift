import Foundation

/// kmap's repair marks in a borrowed TYP: their sections, their numbers, and a free
/// number for a mark the style already draws something else with.
extension TypAugment {
    /// What the sections in `StyleAssets.repairMarks` are for, so a missing one can be named.
    static let repairTypes: [(kind: MapElementKind, code: Int, what: String)] = [
        (.line, 0x0d, "the repair link"),
        (.point, 0x660b, "the mark on a repair link")
    ]

    /// The label kmap's own marks carry, and the one thing that tells a copy of them
    /// from a style's own drawing on the same number.
    static let repairLabel = "Repaired link"

    /// The tag the repair pass writes on a link and on its mark; the rules that carry
    /// it are kmap's own, and their sections go into every TYP a build uses.
    static let repairTag = PBFRewriter.repairTag

    /// A draw-order entry is read to the end of its line, so a note behind the level
    /// makes the compiler refuse the whole file. kmap wrote such a note itself for a
    /// while; a file it touched is mended here, in the copy this build compiles.
    static func repairedDrawOrder(_ text: String) -> String {
        var inside = false
        var mended = false
        var out: [String] = []
        for line in text.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if trimmed == "[_draworder]" { inside = true } else if trimmed == "[end]" { inside = false }
            guard inside, line.contains(";"),
                trimmed.hasPrefix("type="), let cut = line.firstIndex(of: ";")
            else {
                out.append(line)
                continue
            }
            out.append(
                String(line[line.startIndex..<cut])
                    .trimmingCharacters(in: .whitespaces)
            )
            mended = true
        }
        return mended ? out.joined(separator: "\n") : text
    }

    /// The plain line numbers a receiver will route on. A repair link that leaves them
    /// is drawn and not driven, which is the one thing it exists to be.
    static let routableLines = 0x01...0x16

    /// The numbers kmap's own rules emit for this kind. A mark may not move onto one of
    /// them: it would then be drawn on every footway or shop that number carries.
    static func numbersInUse(_ kind: MapElementKind, by rules: URL?) -> Set<Int> {
        guard let rules,
            let text = try? String(
                contentsOf: rules.appendingPathComponent(kind.ruleFile),
                encoding: .utf8
            )
        else { return [] }
        var out: Set<Int> = []
        var rest = Substring(text)
        while let open = rest.range(of: "[0x") {
            rest = rest[open.upperBound...]
            let digits = rest.prefix { $0.isHexDigit }
            if let code = Int(digits, radix: 16) { out.insert(code) }
        }
        return out
    }

    /// A number of this kind nothing else means: neither the borrowed style's drawing nor
    /// kmap's own rules. Taken from the top of the plain range downward, so it sits far
    /// from the numbers a style usually fills. A line that has to stay routable is looked
    /// for among the numbers that route first, and settles for one that does not route
    /// only when every routing number is spoken for.
    static func freeCode(
        _ kind: MapElementKind,
        in source: TypSource,
        avoiding taken: Set<Int>,
        routable: Bool = false
    ) -> Int? {
        let range: [Int]
        switch kind {
        case .line:
            range =
                routable
                ? Array(routableLines.reversed()) + Array((0x17...0x3f).reversed())
                : Array((0x01...0x3f).reversed())
        case .polygon: range = Array((0x01...0x7f).reversed())
        case .point: range = Array((0x01...0x7f).reversed()).map { $0 << 8 }
        }
        return range.first { source.section(kind, $0) == nil && !taken.contains($0) }
    }

    /// Splits a fragment of TYP source into its sections, each kept verbatim so that the
    /// comments describing the drawing travel with it.
    static func sections(of fragment: String) -> [(code: Int, text: String)] {
        var out: [(code: Int, text: String)] = []
        let lines = fragment.components(separatedBy: "\n")
        var index = 0

        while index < lines.count {
            let header = lines[index].trimmingCharacters(in: .whitespaces).lowercased()
            guard ["[_line]", "[_point]", "[_polygon]"].contains(header) else {
                index += 1
                continue
            }
            var end = index + 1
            while end < lines.count,
                lines[end].trimmingCharacters(in: .whitespaces).lowercased() != "[end]"
            {
                end += 1
            }
            guard end < lines.count else { break }

            let block = Array(lines[index...end])
            if let code = block.compactMap(typeCode(of:)).first {
                out.append((code, block.joined(separator: "\n")))
            }
            index = end + 1
        }
        return out
    }

    static func typeCode(of line: String) -> Int? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.lowercased().hasPrefix("type=") else { return nil }
        var value =
            trimmed.dropFirst("type=".count)
            .split(separator: ";").first.map(String.init) ?? ""
        value = value.trimmingCharacters(in: .whitespaces).lowercased()
        if value.hasPrefix("0x") { value.removeFirst(2) }
        return Int(value, radix: 16)
    }

    /// The marks this TYP needs added, and those moved off a number the style already
    /// draws something else with.
    static func marks(
        in source: TypSource,
        rules: URL?
    ) -> (wanted: [(kind: MapElementKind, code: Int, what: String)], moved: [MapElementKind: [Int: Int]]) {
        var moved: [MapElementKind: [Int: Int]] = [:]
        var wanted: [(kind: MapElementKind, code: Int, what: String)] = []
        for mark in repairTypes {
            guard let taken = source.section(mark.kind, mark.code) else {
                wanted.append(mark)
                continue
            }
            // Whose drawing is it? A style that means to draw kmap's repair link says
            // so in the label kmap's own section carries - that is how a copy of it is
            // recognised, and such a style keeps its own drawing. Any other section on
            // that number belongs to the style's own vocabulary - this one draws 0x0d
            // as a pedestrian street - so the mark moves to a number left free rather
            // than wearing a look that means something else.
            if taken.englishLabel == Self.repairLabel { continue }
            // The link itself is a road: it moves only to a number that still routes, and
            // neither of them onto a number kmap's rules already give to something else.
            let inUse = numbersInUse(mark.kind, by: rules).subtracting([mark.code])
            guard
                let free = freeCode(
                    mark.kind,
                    in: source,
                    avoiding: inUse,
                    routable: mark.kind == .line
                )
            else { continue }
            moved[mark.kind, default: [:]][mark.code] = free
            wanted.append((mark.kind, free, mark.what))
        }
        return (wanted, moved)
    }
}
