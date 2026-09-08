import Foundation

/// Which of the three drawing tables a type code belongs to. The same number means different
/// things in each, and nothing in a bare code records its table, so the kind travels with it.
enum MapElementKind: String, CaseIterable, Equatable {
    case point, line, polygon

    /// The rule file that emits this kind, as mkgmap names it.
    var ruleFile: String {
        switch self {
        case .point: return "points"
        case .line: return "lines"
        case .polygon: return "polygons"
        }
    }

    /// The localized plural name. Not `rawValue + "s"`: the raw value is a format token.
    var plural: String {
        switch self {
        case .point: return t("points")
        case .line: return t("lines")
        case .polygon: return t("polygons")
        }
    }

    /// The section header the TYP compiler uses for this kind.
    var typSection: String {
        switch self {
        case .point: return "[_point]"
        case .line: return "[_line]"
        case .polygon: return "[_polygon]"
        }
    }
}

/// What one Garmin type code means, in OSM terms. A TYP styles codes and records nothing
/// about what they stand for; a code means whatever the rule set emitting it puts there.
struct TypeMeaning: Equatable {

    /// One rule that emits this code.
    struct Rule: Equatable {
        /// The condition, trimmed, for display.
        let condition: String
        /// What follows the code inside the brackets, such as `resolution 24 continue`.
        let tail: String
        /// The rule verbatim, spacing included, spanning both lines where the condition and
        /// its type are written apart. A reassignment substitutes on exactly this text.
        let raw: String
    }

    let kind: MapElementKind
    let code: Int

    /// Every rule emitting this code, in file order.
    let rules: [Rule]

    /// The condition text of each, for display.
    var conditions: [String] { rules.map(\.condition) }

    /// `key=value` pairs distilled from those conditions, deduplicated, in first-seen order.
    /// Several are usual: one code is reached by several rules.
    let tags: [String]

    var hex: String { TypeMeaning.hex(code) }

    /// Lowercase `0x…`, padded to two digits below 0x100 and four above, as both the rule
    /// files and the TYP source write it.
    static func hex(_ code: Int) -> String {
        String(format: code > 0xFF ? "0x%04x" : "0x%02x", code)
    }
}

/// Reads mkgmap's rule files and indexes them by the type code each rule emits. Read from
/// the materialized style — mkgmap's default rules plus every kmap edit — which is what a
/// build uses. Read-only.
struct RuleSetIndex {

    private(set) var byKind: [MapElementKind: [Int: TypeMeaning]] = [:]

    /// Every meaning, sorted by kind and then by code.
    var all: [TypeMeaning] {
        MapElementKind.allCases.flatMap { kind in
            (byKind[kind] ?? [:]).values.sorted { $0.code < $1.code }
        }
    }

    func meaning(_ kind: MapElementKind, _ code: Int) -> TypeMeaning? {
        byKind[kind]?[code]
    }

    func codes(_ kind: MapElementKind) -> Set<Int> {
        Set((byKind[kind] ?? [:]).keys)
    }

    var isEmpty: Bool { byKind.values.allSatisfy(\.isEmpty) }

    // MARK: Reading

    /// Parses `points`, `lines` and `polygons` out of a materialized style directory.
    ///
    /// - Returns: nil when the directory holds no rule files, as before the first build.
    static func read(styleDirectory: URL) -> RuleSetIndex? {
        var index = RuleSetIndex()
        var readAnything = false

        for kind in MapElementKind.allCases {
            let url = styleDirectory.appendingPathComponent(kind.ruleFile)
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            readAnything = true

            var rulesByCode: [Int: [TypeMeaning.Rule]] = [:]
            collect(text: text, into: &rulesByCode,
                    includeRoot: styleDirectory, depth: 0)

            var table: [Int: TypeMeaning] = [:]
            for (code, rules) in rulesByCode {
                table[code] = TypeMeaning(kind: kind, code: code, rules: rules,
                                          tags: distillTags(from: rules.map(\.condition)))
            }
            index.byKind[kind] = table
        }
        return readAnything ? index : nil
    }

    /// How many times a rule's exact text occurs in a file, counting only occurrences at the
    /// start of a line. Zero means a reassignment would substitute nothing; more than one
    /// means it would also move a rule.
    static func occurrences(of span: String, in text: String) -> Int {
        guard !span.isEmpty else { return 0 }
        var count = 0
        var search = text.startIndex
        while let found = text.range(of: span, range: search..<text.endIndex) {
            let atLineStart = found.lowerBound == text.startIndex
                || text[text.index(before: found.lowerBound)] == "\n"
            if atLineStart { count += 1 }
            search = found.lowerBound < text.endIndex
                ? text.index(after: found.lowerBound) : text.endIndex
            if search >= text.endIndex { break }
        }
        return count
    }

    // MARK: Parsing

    /// Walks one rule file, following `include` directives. A rule is written either on one
    /// line, or with its condition on one line and its `[0x…]` on the next; both shapes are
    /// handled.
    private static func collect(text: String,
                                into table: inout [Int: [TypeMeaning.Rule]],
                                includeRoot: URL,
                                depth: Int) {
        // The `<finalize>` section runs for every already-matched element and emits no types
        // of its own, so anything below it would be attributed to the wrong rule.
        let body = text.components(separatedBy: "\n<finalize>").first ?? text
        let lines = body.components(separatedBy: "\n")

        var pendingCondition = ""
        /// Index of the rule's first line, so the exact span can be taken.
        var ruleStart: Int?

        for index in lines.indices {
            let line = lines[index].trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }

            if line.hasPrefix("include ") {
                guard depth < 4 else { continue }
                followInclude(line, root: includeRoot, into: &table, depth: depth)
                continue
            }

            guard let bracket = firstTypeBracket(in: line) else {
                // A line with no bracket is a condition whose type is still to come, or a
                // continuation of one.
                let text = stripTrailingComment(line)
                if looksLikeCondition(text) {
                    if continues(pendingCondition) {
                        pendingCondition += " " + text
                    } else {
                        pendingCondition = text
                        ruleStart = index
                    }
                }
                continue
            }

            let head = stripTrailingComment(String(line[line.startIndex..<bracket.range]))
                .trimmingCharacters(in: .whitespaces)
            // An action block with no condition (`{name '…'} [0x…]`) continues the previous
            // line, as does a condition left hanging on a boolean operator.
            let condition: String
            if !looksLikeCondition(head) {
                condition = pendingCondition
            } else if continues(pendingCondition) {
                condition = pendingCondition + " " + head
            } else {
                condition = head
                ruleStart = index
            }

            if !condition.isEmpty {
                // The raw span runs from the condition's line to this one, verbatim.
                let first = min(ruleStart ?? index, index)
                let raw = lines[first...index].joined(separator: "\n")
                table[bracket.code, default: []].append(
                    TypeMeaning.Rule(condition: condition, tail: bracket.tail, raw: raw))
            }
            pendingCondition = ""
            ruleStart = nil
        }
    }

    /// True where a condition ends on a boolean operator, so the next line finishes it
    /// rather than starting a rule of its own.
    private static func continues(_ condition: String) -> Bool {
        condition.hasSuffix("|") || condition.hasSuffix("&")
    }

    private static func followInclude(_ line: String, root: URL,
                                      into table: inout [Int: [TypeMeaning.Rule]],
                                      depth: Int) {
        // Directive form: `include 'inc/contour_lines';`
        guard let open = line.firstIndex(of: "'"),
              let close = line.lastIndex(of: "'"), open < close else { return }
        let name = String(line[line.index(after: open)..<close])
        let url = root.appendingPathComponent(name)
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return }
        collect(text: text, into: &table, includeRoot: root, depth: depth + 1)
    }

    /// Finds the first `[0x…` on a line and returns its code, the bracket's index, and the
    /// text between the code and the closing bracket. Other brackets are skipped.
    private static func firstTypeBracket(in line: String)
        -> (code: Int, range: String.Index, tail: String)? {
        var search = line.startIndex
        while let open = line[search...].firstIndex(of: "[") {
            let after = line.index(after: open)
            let rest = line[after...]
            if rest.hasPrefix("0x") || rest.hasPrefix("0X") {
                let digits = rest.dropFirst(2).prefix { $0.isHexDigit }
                if !digits.isEmpty, let code = Int(digits, radix: 16) {
                    // The resolution and any `continue`, `with_actions` or `default_name`,
                    // carried across unchanged.
                    let afterCode = rest.dropFirst(2 + digits.count)
                    let closing = afterCode.firstIndex(of: "]") ?? afterCode.endIndex
                    let tail = afterCode[afterCode.startIndex..<closing]
                        .trimmingCharacters(in: .whitespaces)
                    return (code, open, tail)
                }
            }
            guard after < line.endIndex else { return nil }
            search = after
        }
        return nil
    }

    /// True where the text reads as a rule condition rather than a bare action block.
    private static func looksLikeCondition(_ text: String) -> Bool {
        guard !text.isEmpty else { return false }
        // A line starting with `{` is an action block continuing the line above it.
        if text.hasPrefix("{") { return false }
        return text.contains("=") || text.contains("(")
    }

    /// Drops a `#` comment, but only one starting outside a quoted string: a quoted label
    /// template may contain any character.
    private static func stripTrailingComment(_ line: String) -> String {
        var quote: Character? = nil
        for (offset, ch) in line.enumerated() {
            if let q = quote {
                if ch == q { quote = nil }
            } else if ch == "'" || ch == "\"" {
                quote = ch
            } else if ch == "#" {
                let cut = line.index(line.startIndex, offsetBy: offset)
                return String(line[line.startIndex..<cut]).trimmingCharacters(in: .whitespaces)
            }
        }
        return line
    }

    // MARK: Tags

    /// Key prefixes that are internal rather than descriptive.
    private static let syntheticPrefixes = ["mkgmap:", "kmap:", "addr:"]

    /// Keys that qualify a rule without describing what it matches, such as `name=*`.
    private static let qualifyingKeys: Set<String> = ["name", "ref", "area", "oneway",
                                                      "access", "layer", "tunnel", "bridge"]

    /// Pulls `key=value` pairs out of rule conditions in the order they appear. A wildcard is
    /// kept only where its condition names nothing concrete. Negations are dropped.
    static func distillTags(from conditions: [String]) -> [String] {
        var out: [String] = []
        var seen = Set<String>()

        func add(_ pair: String) {
            if seen.insert(pair).inserted { out.append(pair) }
        }

        for condition in conditions {
            var concrete: [String] = []
            var wildcards: [String] = []

            for token in tokens(in: condition) {
                guard let eq = token.firstIndex(of: "=") else { continue }
                let key = String(token[token.startIndex..<eq])
                let value = String(token[token.index(after: eq)...])
                guard !key.isEmpty, !value.isEmpty else { continue }
                guard !syntheticPrefixes.contains(where: { key.hasPrefix($0) }) else { continue }
                guard !qualifyingKeys.contains(key) else { continue }
                if value == "*" { wildcards.append("\(key)=*") } else { concrete.append("\(key)=\(value)") }
            }
            (concrete.isEmpty ? wildcards : concrete).forEach(add)
        }
        return out
    }

    /// Splits a condition into `key=value` candidates on the boolean operators, ignoring
    /// anything inside an action block or a quoted string.
    private static func tokens(in condition: String) -> [String] {
        var out: [String] = []
        var current = ""
        var quote: Character? = nil
        var braces = 0

        func flush() {
            let t = current.trimmingCharacters(in: CharacterSet(charactersIn: " \t()!"))
            if !t.isEmpty { out.append(t) }
            current = ""
        }

        for ch in condition {
            if let q = quote {
                if ch == q { quote = nil }
                continue
            }
            switch ch {
            case "'", "\"": quote = ch
            case "{": braces += 1
            case "}": if braces > 0 { braces -= 1 }
            default:
                guard braces == 0 else { continue }
                if ch == "&" || ch == "|" {
                    flush()
                } else {
                    current.append(ch)
                }
            }
        }
        flush()

        // `a!=b` is a negation, and `is_closed()=false` is a call on the geometry rather
        // than a tag on the object.
        return out.filter {
            !$0.contains("!=") && !$0.contains("<") && !$0.contains(">")
                && !$0.contains("(") && !$0.contains(")")
        }
    }
}
