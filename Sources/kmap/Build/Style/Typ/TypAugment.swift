import Foundation

/// Adds kmap's own sections to whatever TYP a build is using: the repair pass emits two
/// type codes no other style draws. The sections travel with the build - the original file
/// is never written to, a TYP already defining one of these types keeps its own, and
/// everything else comes through verbatim with the sections appended at the end.
enum TypAugment {
    /// Where a copy goes when the caller names nowhere. A build names its own scratch
    /// directory instead, so the copy - which carries the theme applied to it - is removed
    /// with the rest of that build's work files.
    static var directory: URL {
        Paths.styles.appendingPathComponent("build-typ", isDirectory: true)
    }

    /// What the sections in `StyleAssets.repairMarks` are for, so a missing one can be named.
    static let repairTypes: [(kind: MapElementKind, code: Int, what: String)] = [
        (.line, 0x0d, "the repair link"),
        (.point, 0x660b, "the mark on a repair link")
    ]

    /// The ground tints a wood is drawn over: a residential area, a village, a suburb
    /// and the grounds of a hotel or a camp. OSM draws a wood across a settlement
    /// without cutting either out, and the wood is the ground truth of the 2: the tint
    /// goes under it, and the houses and roads are drawn over the 2 of them.
    static let groundTints = [0x10, 0x03, 0x02, 0x21]

    /// What is drawn over a ground tint, on kmap's numbers: a wood, which is its floor
    /// and the 3 kinds drawn on it, and an orchard.
    static let woods = [0x59, 0x50, 0x57, 0x58, 0x4e]

    /// Open ground and what is farmed in the open: the covers a ground tint stays over.
    /// A meadow, a field or a plateau drawn round a village is the land the village
    /// stands in. Scrub and its floor, vineyards, allotments, fields, farms, grass,
    /// heath, plateaux, tundra, sand and ice.
    static let openCovers: Set<Int> = [
        0x4f, 0x5b, 0x1b, 0x5a, 0x1c, 0x26, 0x55, 0x1e, 0x1f, 0x52, 0x53, 0x4d
    ]

    /// A wood proper, without the orchard: what open ground may lie on and still show.
    static let forest = [0x59, 0x50, 0x57, 0x58]

    /// Open ground that OSM draws across a wood with no hole cut for it: a glade, a
    /// patch of scrub or heath, a field. Lying on a wood larger than itself it takes a
    /// second number, a copy of its picture on a level over the woods; a patched mkgmap
    /// decides which shape gets it. The step is the level the copy stands on over the
    /// woods: the scrub's floor under everything else.
    static let liftedOverWoods: [(code: Int, step: Int)] = [
        (0x5b, 0), (0x4f, 1), (0x55, 1), (0x1e, 1), (0x1c, 1)
    ]

    /// Where a copy's number is looked for.
    static let copyNumbers = 0x5c...0x7f

    struct Result {
        /// The TYP the build should compile. The original where nothing had to be added.
        let url: URL
        /// Which types were added, for the log.
        let added: [String]
        /// What was said about the day/night pass, where it ran.
        var theme: String?
        /// Why nothing could be added, where that is the case.
        let refusal: String?
        /// Marks that had to move because the borrowed style already draws their
        /// number: old code to new, per kind. The rules emitting them move too.
        var moved: [MapElementKind: [Int: Int]] = [:]
        /// Whether the draw order was rearranged to put the woods over the ground tints.
        var woodsLaidOver = false
        /// The mkgmap option that goes with the copies laid over the woods, where there
        /// are any: `--x-shape-lift=`, each fill with its copy, then the woods.
        var shapeLift: String?
    }

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
    private static func freeCode(
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

    /// Returns the TYP a build should use, adding kmap's sections where they are missing.
    /// Never fails: a style that cannot be augmented still builds, with its repairs drawn
    /// by the device, and the reason is reported in `Result.refusal`.
    static func prepare(
        _ typURL: URL?,
        theme: TypEdit.Theme = .all,
        into destination: URL? = nil,
        rules: URL? = nil,
        liftingOpenGround: Bool = false
    ) -> Result? {
        guard let typURL, FileTools.exists(typURL) else { return nil }

        // A compiled TYP cannot have sections appended to it as text; importing it
        // decompiles it.
        guard typURL.pathExtension.lowercased() == "txt" else {
            // The day/night pass reads the same text the repair marks are added to, so a
            // compiled TYP defeats both.
            let what =
                theme == .all
                ? "kmap's repair marks cannot be added to it"
                : "kmap can neither drop its night colours nor add "
                    + "the repair marks"
            return Result(
                url: typURL,
                added: [],
                theme: nil,
                refusal: "\(typURL.lastPathComponent) is a compiled TYP, so \(what)"
                    + " — import it again to decompile it, and it will work"
            )
        }
        guard let original = try? String(contentsOf: typURL, encoding: .utf8) else {
            return Result(url: typURL, added: [], refusal: nil)
        }

        // The theme pass runs first, so the marks are added to text already in the same
        // terms as the rest of the file.
        var text = repairedDrawOrder(original)
        var themeNote: String?
        if theme != .all {
            let pass = TypEdit.keeping(theme, in: text)
            text = pass.text
            themeNote =
                pass.elements > 0
                ? "packed \(theme.rawValue) colours only — \(pass.elements) element(s)"
                : "nothing to change: this TYP names no night colours"
        }

        let source = TypSource.parse(text)
        // A borrowed style may already draw the number kmap repairs with - this one
        // draws 0x0d as a pedestrian street - and the mark would then wear that look
        // instead of its own. Such a mark moves to a number the style leaves free, and
        // the rules that emit it are moved with it.
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
        // Open ground under a settlement's tint, and a wood over it, whatever order
        // the style has them in.
        var orderLines = text.components(separatedBy: "\n")
        let woodsLaidOver = TypEdit.layWoodsOverTints(
            &orderLines,
            tints: groundTints,
            woods: woods,
            covers: openCovers
        )
        if woodsLaidOver { text = orderLines.joined(separator: "\n") }

        // A wood over the tints and the tints over open ground leaves a glade under the
        // wood it is drawn across. Each kind of open ground gets a copy of its picture
        // on a number nothing uses, over the woods, for mkgmap to hand out.
        var copies: [(code: Int, text: String)] = []
        var shapeLift: String?
        if liftingOpenGround {
            var taken = numbersInUse(.polygon, by: rules).union(moved[.polygon].map { Set($0.values) } ?? [])
            var pairs: [(from: Int, to: Int, step: Int)] = []
            for open in liftedOverWoods {
                // The nearest free number over the ones kmap already draws, not one from
                // the top of the range: no receiver has been seen to draw those.
                guard let section = source.section(.polygon, open.code),
                    let free = copyNumbers.first(where: {
                        source.section(.polygon, $0) == nil && !taken.contains($0)
                    })
                else { continue }
                taken.insert(free)
                pairs.append((open.code, free, open.step))
                let copy = source.lines[section.lines].map { line in
                    typeCode(of: line) == nil ? line : TypEdit.indentation(of: line) + "Type=" + TypeMeaning.hex(free)
                }
                copies.append((free, copy.joined(separator: "\n")))
            }
            let held = forest.filter { code in source.drawOrder.contains { $0.code == code } }
            var liftLines = text.components(separatedBy: "\n")
            if !pairs.isEmpty, !held.isEmpty,
                TypEdit.layOverWoods(&liftLines, lifted: pairs.map { ($0.to, $0.step) }, woods: woods)
            {
                text = liftLines.joined(separator: "\n")
                shapeLift =
                    "--x-shape-lift="
                    + pairs.map { TypeMeaning.hex($0.from) + ">" + TypeMeaning.hex($0.to) }.joined(separator: ",")
                    + ":" + held.map(TypeMeaning.hex).joined(separator: ",")
            } else {
                copies = []
            }
        }

        guard !wanted.isEmpty || text != original else {
            return Result(
                url: typURL,
                added: [],
                theme: themeNote,
                refusal: nil,
                moved: [:]
            )
        }

        var additions = sections(of: StyleAssets.repairMarks)
            .filter { section in
                wanted.contains { $0.code == section.code }
                    || moved.values.contains { $0[section.code] != nil }
            }
        additions.append(contentsOf: copies)
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
        if !additions.isEmpty {
            if !text.hasSuffix("\n") { text += "\n" }
            text += "\n; " + String(repeating: "-", count: 74) + "\n"
            text += "; Added by kmap for this build. Not part of \(typURL.lastPathComponent);\n"
            text += "; the file you own is untouched.\n"
            text += "; " + String(repeating: "-", count: 74) + "\n\n"
            text += additions.map(\.text).joined(separator: "\n\n")
            if !text.hasSuffix("\n") { text += "\n" }
            // Passed again after appending, so the added marks carry the same theme as
            // everything around them.
            if theme != .all { text = TypEdit.keeping(theme, in: text).text }
        }

        let folder = destination ?? directory
        let written = folder.appendingPathComponent(typURL.lastPathComponent)

        // The original is never written to. The copy keeps the original's name, so a style
        // living in the destination folder would otherwise be overwritten by its own copy.
        guard written.standardizedFileURL != typURL.standardizedFileURL else {
            return Result(
                url: typURL,
                added: [],
                theme: themeNote,
                refusal: "\(typURL.lastPathComponent) sits where the build writes"
                    + " its own copy, so it is used as it is — kmap will not"
                    + " write over a TYP you own"
            )
        }

        Paths.ensure(folder)
        // Stale copies from the shared folder: the shared name would let a theme chosen
        // once outlive the build that chose it. Removed only when nothing being read lives
        // there.
        if folder != directory,
            !typURL.standardizedFileURL.path.hasPrefix(directory.standardizedFileURL.path)
        {
            FileTools.removeIfPresent(directory)
        }
        guard (try? FileTools.write(text, to: written)) != nil else {
            return Result(url: typURL, added: [], theme: nil, refusal: nil)
        }

        return Result(
            url: written,
            added: additions.isEmpty
                ? []
                : wanted.map { mark in
                    let moved = moved[mark.kind]?.first { $0.value == mark.code }
                    return "\(TypeMeaning.hex(mark.code)) — \(mark.what)"
                        + (moved.map {
                            " (moved off \(TypeMeaning.hex($0.key)),"
                                + " which this style already draws)"
                        } ?? "")
                },
            theme: themeNote,
            refusal: nil,
            moved: moved,
            woodsLaidOver: woodsLaidOver,
            shapeLift: shapeLift
        )
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

    private static func typeCode(of line: String) -> Int? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.lowercased().hasPrefix("type=") else { return nil }
        var value =
            trimmed.dropFirst("type=".count)
            .split(separator: ";").first.map(String.init) ?? ""
        value = value.trimmingCharacters(in: .whitespaces).lowercased()
        if value.hasPrefix("0x") { value.removeFirst(2) }
        return Int(value, radix: 16)
    }
}
