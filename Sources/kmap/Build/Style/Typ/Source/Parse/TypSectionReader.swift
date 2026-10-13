import Foundation

extension TypSection {
    /// A section read as mkgmap reads one: entry by entry, the later line winning.
    struct Reader {
        let kind: MapElementKind
        private var comments: [String]
        private var labels: [(language: Int, text: String)] = []
        private var fontStyle: String?
        private var dayLabelColour: String?
        private var nightLabelColour: String?
        private var lineWidth: Int?
        private var borderWidth: Int?
        private var usesOrientation = false
        private var xpm: XpmBlock?
        private var dayXpm: XpmBlock?
        private var nightXpm: XpmBlock?
        // Any kind as mkgmap reads it: `Type=` sets the type, and the subtype too from a
        // number of 0x100 or more; `SubType=` sets the subtype; the later line wins.
        private var pointType: Int?
        private var pointSubtype = 0
        private var hasSubtype = false

        /// Comments above the header belong to the section.
        init(kind: MapElementKind, leadingComments: [String]) {
            self.kind = kind
            comments = leadingComments
        }

        /// Reads the section's body.
        mutating func read(_ body: [String]) {
            var i = 0
            while i < body.count {
                let raw = body[i]
                let line = raw.trimmingCharacters(in: .whitespaces)
                if line.isEmpty { i += 1; continue }
                if line.hasPrefix(";") { comments.append(line); i += 1; continue }

                guard let (key, value) = TypSource.keyValue(line) else { i += 1; continue }

                switch key.uppercased() {
                case "TYPE":
                    if let number = TypSource.decodedInteger(value) {
                        pointType = number >= 0x100 ? number >> 8 : number & 0xFF
                        if number >= 0x100 {
                            pointSubtype = number & 0xFF
                            hasSubtype = true
                        }
                    }
                case "SUBTYPE":
                    if let number = TypSource.decodedInteger(value) {
                        pointSubtype = number & 0xFF
                        hasSubtype = true
                    }
                case "STRING":
                    labels.append(TypSource.label(in: value))
                case "FONTSTYLE":
                    fontStyle = value
                case "DAYCUSTOMCOLOR":
                    dayLabelColour = value
                case "NIGHTCUSTOMCOLOR":
                    nightLabelColour = value
                case "LINEWIDTH":
                    lineWidth = TypSource.decodedInteger(value)
                case "BORDERWIDTH":
                    borderWidth = TypSource.decodedInteger(value)
                case "USEORIENTATION":
                    usesOrientation = value.hasPrefix("Y")
                case "XPM", "DAYXPM", "NIGHTXPM":
                    let (block, consumed) = XpmBlock.read(header: value, following: body, from: i + 1)
                    // mkgmap takes a point's `Xpm=` and `DayXpm=` alike, the later winning.
                    switch key.uppercased() {
                    case "XPM":
                        xpm = block
                        if kind == .point { dayXpm = nil }
                    // A line or polygon has 1 picture: mkgmap passes over the others.
                    case "DAYXPM" where kind == .point:
                        dayXpm = block
                        xpm = nil
                    case "NIGHTXPM" where kind == .point:
                        nightXpm = block
                    default: break
                    }
                    i = consumed - 1
                default:
                    break
                }
                i += 1
            }
        }

        /// The section read, spanning `lines` of the file; nil where it named no type.
        func section(lines: Range<Int>) -> TypSection? {
            guard let pointType else { return nil }
            // `Type=0x2f` names the point 0x2f00 to mkgmap, subtype 0, as everywhere in kmap; a
            // line or polygon is its type alone, or `(type << 8) | subtype` where it has one.
            let code = kind == .point || hasSubtype ? (pointType << 8) | pointSubtype : pointType
            return TypSection(
                kind: kind,
                code: code,
                lines: lines,
                comments: comments,
                labels: labels,
                fontStyle: fontStyle,
                dayLabelColour: dayLabelColour,
                nightLabelColour: nightLabelColour,
                lineWidth: lineWidth,
                borderWidth: borderWidth,
                usesOrientation: usesOrientation,
                xpm: xpm,
                dayXpm: dayXpm,
                nightXpm: nightXpm
            )
        }
    }
}
