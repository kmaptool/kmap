import Foundation

/// A shipped style, as a table of colours against kmap's own type codes.
///
/// The table is the source and the TYP is generated from it. The codes are always kmap's
/// own: a third-party TYP is written against its own rule set, so what is borrowed from
/// one is the palette, never the type codes.
struct StylePalette {
    var name = ""
    var summary = ""
    private(set) var polygons: [Polygon] = []
    private(set) var lines: [Line] = []

    struct Polygon {
        let code: Int
        /// Draw order. Higher is painted later, so it wins where two overlap.
        let level: Int
        let day: String
        let night: String
        let name: String
    }

    struct Line {
        let code: Int
        /// Total width in pixels, casing included.
        let width: Int
        let day: String
        /// The border either side of the fill; nil for a line drawn in one colour.
        let casing: String?
        let name: String
    }

    /// Reads the table. A line it cannot parse is reported rather than skipped: a mistyped
    /// colour that vanishes leaves a type for the device to draw its own way.
    ///
    /// - Throws: `Trouble.badLine` naming the line number and what was expected.
    static func read(_ text: String) throws -> StylePalette {
        var out = StylePalette()
        for (number, raw) in text.components(separatedBy: "\n").enumerated() {
            var line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#") else { continue }
            // A trailing note is a note, not part of the name. ` # ` and not bare `#`,
            // because every colour in the table starts with one — and none with a space.
            if let note = line.range(of: " # ") {
                line = String(line[..<note.lowerBound]).trimmingCharacters(in: .whitespaces)
            }
            let parts = line.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
            func fail(_ why: String) -> Trouble {
                Trouble.badLine(number + 1, line, why)
            }
            switch parts.first {
            case "name":
                out.name = parts.dropFirst().joined(separator: " ")
            case "summary":
                out.summary = parts.dropFirst().joined(separator: " ")
            case "poly":
                guard parts.count >= 5, let code = hex(parts[1]),
                      let level = Int(parts[2]), isColour(parts[3])
                else { throw fail("expected: poly <code> <level> <day> [night] <name>") }
                let hasNight = isColour(parts[4])
                let name = parts.dropFirst(hasNight ? 5 : 4).joined(separator: " ")
                guard !name.isEmpty else { throw fail("no name") }
                out.polygons.append(Polygon(code: code, level: level, day: parts[3],
                                            night: hasNight ? parts[4] : parts[3],
                                            name: name))
            case "line":
                guard parts.count >= 4, let code = hex(parts[1]),
                      let width = Int(parts[2]), isColour(parts[3])
                else { throw fail("expected: line <code> <width> <day> [casing] <name>") }
                let hasCasing = parts.count > 4 && isColour(parts[4])
                let name = parts.dropFirst(hasCasing ? 5 : 4).joined(separator: " ")
                guard !name.isEmpty else { throw fail("no name") }
                out.lines.append(Line(code: code, width: width, day: parts[3],
                                      casing: hasCasing ? parts[4] : nil, name: name))
            default:
                throw fail("unknown kind \(parts.first ?? "")")
            }
        }
        return out
    }

    private static func isColour(_ s: String) -> Bool {
        s.count == 7 && s.hasPrefix("#") && s.dropFirst().allSatisfy(\.isHexDigit)
    }

    /// `0x1f` or `1f`, either way. Local rather than an `Int.init?(hex:)`: function
    /// references drop argument labels, so such an initialiser captures `flatMap(Int.init)`.
    private static func hex(_ text: String) -> Int? {
        let body = text.hasPrefix("0x") ? String(text.dropFirst(2)) : text
        return Int(body, radix: 16)
    }

    enum Trouble: Error, CustomStringConvertible, LocalizedError {
        case badLine(Int, String, String)
        var description: String {
            guard case .badLine(let n, let text, let why) = self else { return "" }
            return "palette line \(n): \(why) — \(text)"
        }
    }
}
