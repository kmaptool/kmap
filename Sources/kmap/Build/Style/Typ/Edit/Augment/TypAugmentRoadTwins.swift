import Foundation

/// The twin wears the road's look, the road is transparent.
extension TypAugment {
    /// The first block free in the TYP and the rules is used.
    static let twinBases = [0x11f00, 0x11e00, 0x11d00, 0x11c00, 0x11b00]

    /// Edits the build's TYP copy in place.
    ///
    /// - Returns: road code to twin code for the roads the TYP draws.
    static func twinRoads(in typ: URL, roads: Set<Int>, taken: Set<Int>) -> [Int: Int] {
        guard let data = try? Data(contentsOf: typ) else { return [:] }
        let (text, byteForByte) = TypSource.decoding([UInt8](data))
        let source = TypSource.parse(text)
        // An extended subtype is 0x1f at most.
        let drawn = source.sections.filter { $0.kind == .line && roads.contains($0.code) && $0.code <= 0x1f }
        guard let base = freeBase(for: drawn, in: source, taken: taken) else { return [:] }
        let out = twinned(drawn, in: source.lines, base: base)
        let bytes = TypSource.bytesToWrite(out, declaring: true, byteForByte: byteForByte)
        guard (try? FileTools.write(bytes, to: typ)) != nil else { return [:] }
        return Dictionary(drawn.map { ($0.code, base | $0.code) }, uniquingKeysWith: { first, _ in first })
    }

    private static func freeBase(for drawn: [TypSection], in source: TypSource, taken: Set<Int>) -> Int? {
        guard !drawn.isEmpty else { return nil }
        let used = Set(source.sections.filter { $0.kind == .line }.map(\.code)).union(taken)
        return twinBases.first { base in drawn.allSatisfy { !used.contains(base | $0.code) } }
    }

    /// The roads made transparent, their looks appended under the twin codes.
    private static func twinned(_ drawn: [TypSection], in source: [String], base: Int) -> String {
        var lines = source
        var copies: [String] = []
        // From the end, so earlier ranges stay valid.
        for section in drawn.sorted(by: { $0.lines.lowerBound > $1.lines.lowerBound }) {
            let original = Array(lines[section.lines])
            copies.insert(copy(original, code: base | section.code), at: 0)
            let labels = original.filter { key(of: $0).hasPrefix("string") }
            lines.replaceSubrange(section.lines, with: nothing(code: section.code, labels: labels))
        }
        var out = lines.joined(separator: "\n")
        if !out.hasSuffix("\n") { out += "\n" }
        out += "\n; Road twins added by kmap: the road is transparent, its twin wears its look.\n\n"
        return out + copies.joined(separator: "\n\n") + "\n"
    }

    private static func copy(_ section: [String], code: Int) -> String {
        var copy = section.map { key(of: $0) == "type" ? "Type=" + TypeMeaning.hex(code) : $0 }
        if copy.last?.trimmingCharacters(in: .whitespaces).lowercased() != "[end]" { copy.append("[end]") }
        return copy.joined(separator: "\n")
    }

    private static func key(of line: String) -> String {
        guard let equals = line.firstIndex(of: "=") else { return "" }
        return line[..<equals].trimmingCharacters(in: .whitespaces).lowercased()
    }

    /// Labels kept for the receiver's lists, hidden on the map.
    private static func nothing(code: Int, labels: [String]) -> [String] {
        var out = ["[_line]", "Type=" + TypeMeaning.hex(code)]
        out.append("Xpm=\"32 1 2 1\"")
        out.append("\"! c #000000\"")
        out.append("\"# c none\"")
        out.append("\"" + String(repeating: "#", count: 32) + "\"")
        out += labels
        out.append("FontStyle=NoLabel")
        out.append("[end]")
        return out
    }
}
