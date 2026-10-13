import Foundation

extension TypSource {
    /// Reads a TYP source as mkgmap does: line by line, a block from its header to its end.
    static func parse(_ text: String) -> TypSource {
        var parser = Parser(text)
        return parser.parse()
    }

    /// A pass over a TYP source's lines, gathering the identity, the sections, the draw
    /// order and the codes left unstyled on purpose.
    struct Parser {
        private let lines: [String]
        private var index = 0
        /// Comments above a section header belong to it.
        private var pendingComments: [String] = []
        private var familyID: Int?
        private var productID: Int?
        private var codePage: Int?
        private var sections: [TypSection] = []
        private var drawOrder: [(code: Int, level: Int)] = []
        private var unstyled: [MapElementKind: Set<Int>] = [:]

        init(_ text: String) {
            // `Lines` rather than `components(separatedBy:)`: Swift treats "\r\n" as one
            // Character, so the obvious splits disagree across platforms. The trailing blank
            // is kept so a file ending in a newline still ends in one after a round trip.
            lines = TextLines.keepingTrailingBlank(text)
        }

        mutating func parse() -> TypSource {
            while index < lines.count { step() }
            return TypSource(
                lines: lines,
                familyID: familyID,
                productID: productID,
                codePage: codePage,
                sections: sections,
                drawOrder: drawOrder,
                deliberatelyUnstyled: unstyled
            )
        }

        /// 1 line: a blank or a comment, or a header and the block under it.
        private mutating func step() {
            let line = lines[index].trimmingCharacters(in: .whitespaces)
            if line.isEmpty {
                pendingComments.removeAll()
                index += 1
                return
            }
            if line.hasPrefix(";") {
                if let marker = TypSource.parseUnstyledMarker(line) {
                    unstyled[marker.kind, default: []].formUnion(marker.codes)
                }
                pendingComments.append(line)
                index += 1
                return
            }
            guard TypSource.passingSymbols(line).hasPrefix("[") else {
                pendingComments.removeAll()
                index += 1
                return
            }
            let (end, next) = TypSource.blockEnd(of: lines, from: index)
            read(
                header: TypSource.header(of: line) ?? line.lowercased(),
                body: Array(lines[(index + 1)..<end]),
                spanning: index..<next
            )
            pendingComments.removeAll()
            index = next
        }

        private mutating func read(header: String, body: [String], spanning span: Range<Int>) {
            switch header {
            case "[_id]":
                readIdentity(body)
            case "[_draworder]":
                drawOrder = TypSource.parseDrawOrder(body)
            case "[_point]", "[_line]", "[_polygon]":
                let kind: MapElementKind =
                    header == "[_point]"
                    ? .point
                    : (header == "[_line]" ? .line : .polygon)
                var reader = TypSection.Reader(kind: kind, leadingComments: pendingComments)
                reader.read(body)
                if let section = reader.section(lines: span) { sections.append(section) }
            default:
                break
            }
        }

        /// The family, product and code page. A note behind a number is let pass here, as
        /// `TypInfo` lets it.
        private mutating func readIdentity(_ body: [String]) {
            for entry in body {
                guard let (key, noted) = TypSource.keyValue(entry) else { continue }
                let value = TypSource.stripComment(noted)
                switch key.uppercased() {
                case "FID": familyID = TypSource.decodedInteger(value)
                case "PRODUCTCODE": productID = TypSource.decodedInteger(value)
                case "CODEPAGE": codePage = TypSource.decodedInteger(value)
                default: break
                }
            }
        }
    }
}
