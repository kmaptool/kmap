import Foundation

/// The cursor picks a plain line before a road, so each road gets a plain twin it can pick.
extension StyleCatalog {
    /// Splits each road rule: the road on the finest level with `continue`, then a twin
    /// rule with the same condition on the road's levels.
    ///
    /// - Parameter choose: gets the codes that can be twinned and all line codes, returns
    ///   road code to twin code.
    /// - Returns: the number of rules split.
    @discardableResult
    static func addRoadTwins(
        finest: Int,
        in directory: URL,
        choose: (_ roads: Set<Int>, _ taken: Set<Int>) -> [Int: Int]
    ) throws -> Int {
        let url = directory.appendingPathComponent("lines")
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return 0 }
        let lines = TextLines.keepingTrailingBlank(text)
        guard let scan = RoadTwinScan(lines: lines, finest: finest, root: directory) else { return 0 }
        guard !scan.twinnable.isEmpty else { return 0 }
        let twins = choose(scan.twinnable, scan.taken).filter { scan.twinnable.contains($0.key) }
        guard !twins.isEmpty else { return 0 }
        let (out, split) = scan.split(lines, twins: twins, finest: finest)
        guard split > 0 else { return 0 }
        try FileTools.write(out.joined(separator: "\n"), to: url)
        return split
    }
}

/// Line codes in the rules, and the road rules that can be split.
private struct RoadTwinScan {
    var roads: Set<Int> = []
    /// Roads in rules that cannot be split.
    var blocked: Set<Int> = []
    var plain: Set<Int> = []
    var taken: Set<Int> = []
    /// By line index.
    var rules: [Int: RoadRule] = [:]

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
            let condition = RoadRule.closed(by: (pending + [head]).joined(separator: " "))
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
        _ types: [RuleType],
        condition: String,
        alone: Bool,
        at line: Int,
        bracket: ClosedRange<String.Index>,
        finest: Int,
        previous: [Int]
    ) -> [Int] {
        let roadCodes = count(types)
        // No condition: another type of the previous rule.
        guard !RoadRule.test(of: condition).isEmpty else {
            blocked.formUnion(previous + roadCodes)
            return previous + roadCodes
        }
        if alone, let type = types.first, type.isRoad, !condition.contains("kmap:repair"), type.reaches(finest) {
            roads.insert(type.code)
            rules[line] = RoadRule(condition: condition, type: type, bracket: bracket)
        } else {
            blocked.formUnion(roadCodes)
        }
        return roadCodes
    }

    /// Notes every code and the plain ones. Returns the road codes.
    private mutating func count(_ types: [RuleType]) -> [Int] {
        var roadCodes: [Int] = []
        for type in types {
            taken.insert(type.code)
            if type.isRoad { roadCodes.append(type.code) } else { plain.insert(type.code) }
        }
        return roadCodes
    }

    /// Each rule that can be split becomes the road and its twin.
    func split(_ lines: [String], twins: [Int: Int], finest: Int) -> (lines: [String], split: Int) {
        var out: [String] = []
        out.reserveCapacity(lines.count + rules.count)
        for (index, line) in lines.enumerated() {
            if let rule = rules[index], let twin = twins[rule.type.code] {
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

    private static func types(in text: Substring, at brackets: [ClosedRange<String.Index>]) -> [RuleType]? {
        var out: [RuleType] = []
        for bracket in brackets {
            guard let type = RuleType(text[text.index(after: bracket.lowerBound)..<bracket.upperBound])
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
        guard let marks = RuleMarks(text) else { return nil }
        var out: [ClosedRange<String.Index>] = []
        var open: String.Index?
        for (index, ch) in marks.all {
            if ch == "[" { open = index }
            if ch == "]", let start = open { out.append(start...index) }
        }
        return out
    }
}

/// Action braces and type brackets, outside quotes and `${tag}`.
private struct RuleMarks {
    private(set) var all: [(index: String.Index, ch: Character)] = []

    init?<Text: StringProtocol>(_ text: Text) where Text.Index == String.Index {
        var quote: Character?
        var reference = false
        var braces = 0
        var inType = false
        var previous: Character?
        for index in text.indices {
            let ch = text[index]
            defer { previous = ch }
            if let q = quote {
                if ch == q { quote = nil }
            } else if reference {
                if ch == "}" { reference = false }
            } else if ch == "'" || ch == "\"" {
                quote = ch
            } else if ch == "{", previous == "$" {
                reference = true
            } else if inType {
                if ch == "]" {
                    all.append((index, ch))
                    inType = false
                }
            } else if ch == "{" {
                if braces == 0 { all.append((index, ch)) }
                braces += 1
            } else if ch == "}", braces > 0 {
                braces -= 1
                if braces == 0 { all.append((index, ch)) }
            } else if ch == "[", braces == 0 {
                all.append((index, ch))
                inType = true
            }
        }
        guard quote == nil, !inType else { return nil }
    }
}

/// The inside of a type bracket.
private struct RuleType {
    let code: Int
    let codeText: String
    var options: [(key: String, value: String?)] = []

    private static let valued: Set<String> = ["level", "resolution", "default_name", "road_class", "road_speed"]
    private static let flags: Set<String> = [
        "continue", "propagate", "with_actions", "withactions", "no_propagate", "copy", "oneway", "access"
    ]
    static let continuation: Set<String> = ["continue", "propagate", "with_actions", "withactions", "no_propagate"]

    init?(_ inside: Substring) {
        var words: [String] = []
        var current = ""
        var quote: Character?
        for ch in inside {
            if let q = quote {
                current.append(ch)
                if ch == q { quote = nil }
            } else if ch == "'" || ch == "\"" {
                current.append(ch)
                quote = ch
            } else if ch == " " || ch == "\t" || ch == "=" {
                if !current.isEmpty { words.append(current) }
                current = ""
            } else {
                current.append(ch)
            }
        }
        if !current.isEmpty { words.append(current) }
        guard let first = words.first else { return nil }
        let lower = first.lowercased()
        guard let code = lower.hasPrefix("0x") ? Int(lower.dropFirst(2), radix: 16) : Int(lower) else { return nil }
        self.code = code
        codeText = first
        var at = 1
        while at < words.count {
            let key = words[at]
            if Self.valued.contains(key) {
                guard at + 1 < words.count else { return nil }
                options.append((key, words[at + 1]))
                at += 2
            } else if Self.flags.contains(key) {
                options.append((key, nil))
                at += 1
            } else {
                return nil
            }
        }
    }

    var isRoad: Bool { options.contains { $0.key == "road_class" || $0.key == "road_speed" } }

    /// `resolution 22` reaches the finest level, `resolution 20-23` and `level 1-3` do not.
    func reaches(_ finest: Int) -> Bool {
        for (key, value) in options {
            let bounds = (value ?? "").split(separator: "-").compactMap { Int($0) }
            guard let low = bounds.min(), let high = bounds.max() else { continue }
            if key == "resolution", bounds.count > 1 ? high < finest : low > finest { return false }
            if key == "level", bounds.count > 1, low > 0 { return false }
        }
        return true
    }

    static func written(code: String, _ options: [(key: String, value: String?)]) -> String {
        let words = options.map { key, value -> String in
            guard let value else { return key }
            return key + (key == "road_class" || key == "road_speed" ? "=" : " ") + value
        }
        return "[" + ([code] + words).joined(separator: " ") + "]"
    }
}

private struct RoadRule {
    /// With actions, from every line of the rule.
    let condition: String
    let type: RuleType
    let bracket: ClosedRange<String.Index>

    /// Drops the rules of actions alone before the type's own rule.
    static func closed(by text: String) -> String {
        let ends = (RuleMarks(text)?.all ?? []).filter { $0.ch == "}" }.map { text.index(after: $0.index) }
        var start = text.startIndex
        if let last = ends.last {
            if !text[last...].trimmingCharacters(in: .whitespaces).isEmpty {
                start = last
            } else if ends.count > 1 {
                start = ends[ends.count - 2]
            }
        }
        return text[start...].trimmingCharacters(in: .whitespaces)
    }

    static func test(of condition: String) -> String {
        var out = ""
        var from = condition.startIndex
        for (index, ch) in RuleMarks(condition)?.all ?? [] {
            if ch == "{" { out += condition[from..<index] }
            if ch == "}" { from = condition.index(after: index) }
        }
        out += condition[from...]
        return out.trimmingCharacters(in: .whitespaces)
    }

    /// Plain `continue` runs the actions on a copy, so the twin sees the element unchanged.
    func road(in line: String, finest: Int) -> String {
        var options = type.options.filter { !RuleType.continuation.contains($0.key) && $0.key != "level" }
        if let at = options.firstIndex(where: { $0.key == "resolution" }) {
            options[at].value = String(finest)
        } else {
            options.append(("resolution", String(finest)))
        }
        options.append(("continue", nil))
        return line[..<bracket.lowerBound] + RuleType.written(code: type.codeText, options)
            + line[line.index(after: bracket.upperBound)...]
    }

    func twin(code: Int) -> String {
        let options = type.options.filter { $0.key != "road_class" && $0.key != "road_speed" }
        return condition + " " + RuleType.written(code: String(format: "0x%02x", code), options)
    }
}
