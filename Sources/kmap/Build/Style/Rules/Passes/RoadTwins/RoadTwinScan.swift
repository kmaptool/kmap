import Foundation

/// Line codes in the rules, and the road rules that can be split.
struct RoadTwinScan {
    var roads: Set<Int> = []
    /// Roads in rules that cannot be split.
    var blocked: Set<Int> = []
    var plain: Set<Int> = []
    var taken: Set<Int> = []
    /// By line index.
    var rules: [Int: RoadTwinRule] = [:]

    var twinnable: Set<Int> { roads.subtracting(blocked).subtracting(plain) }

    /// Nil where the file cannot be read with certainty.
    init?(lines: [String], finest: Int, root: URL) {
        // Text since the last type.
        var pending: [String] = []
        // Road codes of the previous rule.
        var last: [Int] = []
        for (index, line) in lines.enumerated() {
            let text = Self.uncommented(line)
            let trimmed = text.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { continue }
            if trimmed.hasPrefix("<finalize>") { break }
            if Self.isBlockCommand(trimmed) { return nil }
            if Self.isInclude(trimmed) {
                guard read(include: trimmed, root: root, depth: 0) else { return nil }
                (pending, last) = ([], [])
                continue
            }
            guard let brackets = Self.typeBrackets(in: text), let types = Self.types(in: text, at: brackets)
            else { return nil }
            guard let first = brackets.first, let end = brackets.last else {
                pending.append(trimmed)
                continue
            }
            let head = text[..<first.lowerBound].trimmingCharacters(in: .whitespaces)
            let condition = RoadTwinRule.closed(by: (pending + [head]).joined(separator: " "))
            let alone = types.count == 1 && text[text.index(after: end.upperBound)...].allSatisfy(\.isWhitespace)
            pending = []
            last = add(
                types,
                condition: condition,
                alone: alone,
                at: index,
                bracket: first,
                finest: finest,
                previous: last
            )
        }
    }

    /// Counts a rule's types and keeps it if it can be split. Returns its road codes.
    private mutating func add(
        _ types: [RoadTwinType],
        condition: String,
        alone: Bool,
        at line: Int,
        bracket: ClosedRange<String.Index>,
        finest: Int,
        previous: [Int]
    ) -> [Int] {
        let roadCodes = count(types)
        // A road that brings its own plain line: a via ferrata.
        if condition.contains(StyleCatalog.ownTwin) { return roadCodes }
        // No condition: another type of the previous rule.
        guard !RoadTwinRule.test(of: condition).isEmpty else {
            blocked.formUnion(previous + roadCodes)
            return previous + roadCodes
        }
        if alone, let type = types.first, type.isRoad, !condition.contains("kmap:repair"), type.reaches(finest) {
            roads.insert(type.code)
            rules[line] = RoadTwinRule(condition: condition, type: type, bracket: bracket)
        } else {
            blocked.formUnion(roadCodes)
        }
        return roadCodes
    }

    /// Notes every code and the plain ones. Returns the road codes.
    private mutating func count(_ types: [RoadTwinType]) -> [Int] {
        var roadCodes: [Int] = []
        for type in types {
            taken.insert(type.code)
            if type.isRoad { roadCodes.append(type.code) } else { plain.insert(type.code) }
        }
        return roadCodes
    }

    /// Each rule that can be split becomes the road and its twin.
    func split(
        _ lines: [String],
        twins: [Int: Int],
        borrowing: [Int: [(tag: String, as: Int)]],
        finest: Int
    ) -> (lines: [String], split: Int) {
        var out: [String] = []
        out.reserveCapacity(lines.count + rules.count)
        for (index, line) in lines.enumerated() {
            if let rule = rules[index], let own = twins[rule.type.code] {
                let borrowed = borrowing[rule.type.code]?.lazy.filter { rule.mentions($0.tag) }
                    .compactMap { twins[$0.as] }.first
                let twin = borrowed ?? own
                out.append(rule.road(in: line, finest: finest))
                out.append(rule.twin(code: twin))
            } else {
                out.append(line)
            }
        }
        return (out, out.count - lines.count)
    }

    /// Only `lines` is rewritten, so roads in an include are not split.
    private mutating func read(include line: String, root: URL, depth: Int) -> Bool {
        guard depth < 4, let open = line.firstIndex(where: { $0 == "'" || $0 == "\"" }),
            let close = line[line.index(after: open)...].firstIndex(of: line[open]),
            !line[close...].contains("from")
        else { return false }
        let name = String(line[line.index(after: open)..<close])
        guard let text = try? String(contentsOf: root.appendingPathComponent(name), encoding: .utf8)
        else { return false }
        for line in TextLines.of(text) {
            let text = Self.uncommented(line)
            let trimmed = text.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("<finalize>") { break }
            if Self.isInclude(trimmed) {
                guard read(include: trimmed, root: root, depth: depth + 1) else { return false }
                continue
            }
            guard let brackets = Self.typeBrackets(in: text), let types = Self.types(in: text, at: brackets)
            else { return false }
            blocked.formUnion(count(types))
        }
        return true
    }

    private static func types(in text: Substring, at brackets: [ClosedRange<String.Index>]) -> [RoadTwinType]? {
        var out: [RoadTwinType] = []
        for bracket in brackets {
            guard let type = RoadTwinType(text[text.index(after: bracket.lowerBound)..<bracket.upperBound])
            else { return nil }
            out.append(type)
        }
        return out
    }

    private static func isBlockCommand(_ trimmed: String) -> Bool {
        let word = trimmed.prefix { $0.isLetter }
        let next = trimmed.dropFirst(word.count).first
        switch word {
        case "if": return next == " " || next == "("
        case "else", "end": return next == nil || next == " "
        default: return false
        }
    }

    private static func isInclude(_ trimmed: String) -> Bool {
        guard trimmed.hasPrefix("include") else { return false }
        let next = trimmed.dropFirst("include".count).first
        return next == " " || next == "'" || next == "\""
    }

    private static func uncommented(_ line: String) -> Substring {
        var quote: Character?
        for index in line.indices {
            let ch = line[index]
            if let open = quote {
                if ch == open { quote = nil }
            } else if ch == "'" || ch == "\"" {
                quote = ch
            } else if ch == "#" {
                return line[..<index]
            }
        }
        return line[...]
    }

    private static func typeBrackets(in text: Substring) -> [ClosedRange<String.Index>]? {
        guard let marks = RoadTwinMarks(text) else { return nil }
        var out: [ClosedRange<String.Index>] = []
        var open: String.Index?
        for (index, ch) in marks.all {
            if ch == "[" { open = index }
            if ch == "]", let start = open { out.append(start...index) }
        }
        return out
    }
}
