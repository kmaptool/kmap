import Foundation

/// Adds kmap's own sections to whatever TYP a build is using: the repair pass emits 2
/// type codes no other style draws. The sections travel with the build: the original file
/// is never written to, a TYP already defining one of these types keeps its own, and
/// everything else comes through verbatim with the sections appended.
enum TypAugment {
    /// Where a copy goes when the caller names nowhere. A build names its own scratch
    /// directory instead, so the copy - which carries the theme applied to it - is removed
    /// with the rest of that build's work files.
    static var directory: URL {
        Paths.styles.appendingPathComponent("build-typ", isDirectory: true)
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
            // Handed over as a copy beside the build: mkgmap writes its own copy, with the
            // map's family id, next to the file it is given, and in the user's folder that
            // copy would be taken for a style of its own.
            let folder = destination ?? directory
            let copy = folder.appendingPathComponent(typURL.lastPathComponent)
            var refusal =
                "\(typURL.lastPathComponent) is a compiled TYP, so \(what)"
                + " — import it again to decompile it, and it will work"
            // Already where a copy would go: it is a copy.
            guard !copy.sameFile(as: typURL) else {
                return Result(url: typURL, added: [], theme: nil, refusal: refusal)
            }
            Paths.ensure(folder)
            FileTools.removeIfPresent(copy)
            do {
                try FileTools.copy(typURL, to: copy)
            } catch {
                // Built without it rather than with the user's own file: mkgmap would write
                // its own copy into the user's folder. A part-written copy would be passed on.
                FileTools.removeIfPresent(copy)
                refusal +=
                    "; it could not be copied for this build (\(ErrorWords.of(error))), so the map is built without it"
                return Result(url: copy, added: [], theme: nil, refusal: refusal)
            }
            return Result(url: copy, added: [], theme: nil, refusal: refusal)
        }
        guard let data = try? Data(contentsOf: typURL) else {
            return Result(url: typURL, added: [], refusal: nil)
        }
        // A page kmap cannot read was read byte for byte, and goes to mkgmap the same way.
        let (decoded, byteForByte) = TypSource.decoding([UInt8](data))
        // Line by line in LF alone: Swift reads CRLF as 1 character, which a split on LF
        // leaves whole off Apple's platforms. mkgmap reads either.
        let original = TextLines.keepingTrailingBlank(decoded).joined(separator: "\n")
        let trips = TypSource.codePageTripsMkgmap(original)

        // The theme pass runs first, so the marks are added to text already in the same
        // terms as the rest of the file.
        var text = repairedDrawOrder(
            trips ? TypSource.mendedCodingLine(TypSource.plainCodePageLine(original)) : original
        )
        // A point drawn by night alone crashes mkgmap, which writes its day picture.
        text = TypEdit.givingNightOnlyPointsADay(text)
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
        let (wanted, moved) = marks(in: source, rules: rules)
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
            (copies, shapeLift) = liftOpenGround(in: source, text: &text, rules: rules, moved: moved)
        }

        // Handed through as it is only where mkgmap reads it as kmap does: pure ASCII, or
        // saying how it is written.
        let readsAlike =
            (!original.unicodeScalars.contains { !$0.isASCII } || TypSource.declaringUTF8(original) == original
                || byteForByte) && !trips
        guard !wanted.isEmpty || text != original || !readsAlike else {
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
        // Written as UTF-8, and said to be: without the line mkgmap would read it in the
        // CodePage it names, and the marks' Cyrillic would come out garbled. A page kmap
        // cannot read goes back in its own bytes.
        let bytes = TypSource.bytesToWrite(text, declaring: true, byteForByte: byteForByte)
        do {
            try FileTools.write(bytes, to: written)
        } catch {
            return Result(
                url: typURL,
                added: [],
                theme: nil,
                refusal: "the build's copy of \(typURL.lastPathComponent) could not be written"
                    + " (\(ErrorWords.of(error))), so it is used as it is, without marks or theme"
            )
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
}
