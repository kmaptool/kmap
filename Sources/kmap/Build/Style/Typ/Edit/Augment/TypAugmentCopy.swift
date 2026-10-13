import Foundation

extension TypAugment {
    /// The build's copy of a TYP as it is worked on: its text, how it is written, and what
    /// was done to it on the way.
    struct Copy {
        /// The text as read, line by line in LF alone.
        let original: String
        /// A page kmap cannot read, read byte for byte and written back the same way.
        let byteForByte: Bool
        /// Whether the CodePage line names a page mkgmap trips on.
        let trips: Bool
        private(set) var text: String
        /// What the day/night pass said, where it ran.
        private(set) var themeNote: String?
        /// The repair marks the style lacks, and those moved off a number it draws.
        private(set) var marks:
            (wanted: [(kind: MapElementKind, code: Int, what: String)], moved: [MapElementKind: [Int: Int]]) =
                ([], [:])
        /// Whether the woods were put over the ground tints.
        private(set) var woodsLaidOver = false
        /// The copies of open ground laid over the woods, and the option that goes with them.
        private(set) var lifted: (copies: [(code: Int, text: String)], shapeLift: String?) = ([], nil)
        /// Whether kmap's sections were appended.
        private(set) var addedAny = false

        init(_ data: Data) {
            // A page kmap cannot read was read byte for byte, and goes to mkgmap the same way.
            let (decoded, byteForByte) = TypSource.decoding([UInt8](data))
            self.byteForByte = byteForByte
            // Line by line in LF alone: Swift reads CRLF as 1 character, which a split on
            // LF leaves whole off Apple's platforms. mkgmap reads either.
            original = TextLines.keepingTrailingBlank(decoded).joined(separator: "\n")
            trips = TypSource.codePageTripsMkgmap(original)
            text = TypAugment.repairedDrawOrder(
                trips ? TypSource.mendedCodingLine(TypSource.plainCodePageLine(original)) : original
            )
            // A point drawn by night alone crashes mkgmap, which writes its day picture.
            text = TypEdit.givingNightOnlyPointsADay(text)
        }

        /// Keeps only the day or the night drawing. Runs first, so the marks are added to
        /// text already in the same terms as the rest of the file.
        mutating func keep(_ theme: TypEdit.Theme) {
            let pass = TypEdit.keeping(theme, in: text)
            text = pass.text
            themeNote =
                pass.elements > 0
                ? "packed \(theme.rawValue) colours only — \(pass.elements) element(s)"
                : "nothing to change: this TYP names no night colours"
        }

        /// A borrowed style may already draw the number kmap repairs with - this one draws
        /// 0x0d as a pedestrian street - and the mark would then wear that look instead of
        /// its own. Such a mark moves to a number the style leaves free, and the rules that
        /// emit it are moved with it.
        mutating func mark(in source: TypSource, rules: URL?) {
            marks = TypAugment.marks(in: source, rules: rules)
        }

        /// Open ground under a settlement's tint, and a wood over it, whatever order the
        /// style has them in.
        mutating func layWoodsOverTints() {
            var lines = text.components(separatedBy: "\n")
            woodsLaidOver = TypEdit.layWoodsOverTints(
                &lines,
                tints: TypAugment.groundTints,
                woods: TypAugment.woods,
                covers: TypAugment.openCovers
            )
            if woodsLaidOver { text = lines.joined(separator: "\n") }
        }

        /// A wood over the tints and the tints over open ground leaves a glade under the
        /// wood it is drawn across. Each kind of open ground gets a copy of its picture on
        /// a number nothing uses, over the woods, for mkgmap to hand out.
        mutating func liftOpenGround(in source: TypSource, rules: URL?) {
            lifted = TypAugment.liftOpenGround(in: source, text: &text, rules: rules, moved: marks.moved)
        }

        /// Whether mkgmap would read the original as kmap does: pure ASCII, or saying how it
        /// is written.
        var readsAlike: Bool {
            (!original.unicodeScalars.contains { !$0.isASCII }
                || TypSource.declaringUTF8(original) == original || byteForByte) && !trips
        }

        /// Appends kmap's sections under a note saying whose they are.
        mutating func append(_ additions: [(code: Int, text: String)], from typURL: URL, theme: TypEdit.Theme) {
            guard !additions.isEmpty else { return }
            addedAny = true
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
    }
}
