import Foundation

/// The default rule set, as substitution material. A recovered meaning becomes a sheet
/// line only by naming the exact rule it replaces, substitutions matching lines byte for
/// byte. Reads the materialized base rules and answers which lines a given tag pair
/// begins, and in which file.
struct DefaultRuleBook {
    struct Line {
        let file: String
        let text: String
        /// For a rule written over two lines, the type line that follows the condition.
        /// The substitution is anchored on the condition, which is nearly always unique;
        /// a bare type line is not.
        let continuation: String?
        var isSplit: Bool { continuation != nil }
        private let typeRange: Range<String.Index>

        init?(file: String, text: String, continuation: String? = nil) {
            // The type is read out of whichever line carries it.
            let carrier = continuation ?? text
            guard let open = carrier.firstIndex(of: "["),
                  let found = carrier.range(of: "0x", range: open..<carrier.endIndex)
            else { return nil }
            var end = found.upperBound
            while end < carrier.endIndex, carrier[end].isHexDigit {
                end = carrier.index(after: end)
            }
            self.file = file
            self.text = text
            self.continuation = continuation
            self.typeRange = found.lowerBound..<end
        }

        /// The line the type is written on: the rule itself, or its second line.
        private var carrier: String { continuation ?? text }

        /// The code as the numeric value it is, not as a spelling.
        var code: String {
            let raw = carrier[typeRange].dropFirst(2)
            return String(Int(raw, radix: 16) ?? -1, radix: 16)
        }

        func emits(_ type: Int) -> Bool { code == String(type, radix: 16) }

        /// Rewritten keeping the original token's width, so 0x0b00 does not come back
        /// as 0xb00. mkgmap reads either; the sheet is compared as text.
        func rewritten(to type: Int) -> String {
            let width = carrier.distance(from: typeRange.lowerBound,
                                         to: typeRange.upperBound) - 2
            let hex = String(type, radix: 16)
            let padded = String(repeating: "0", count: max(0, width - hex.count)) + hex
            return carrier.replacingCharacters(in: typeRange, with: "0x" + padded)
        }

        /// The whole rule, re-aimed: one line, or the condition and its type line.
        func replacement(to type: Int) -> [String] {
            isSplit ? [text, rewritten(to: type)] : [rewritten(to: type)]
        }

        /// An extra layer of the same rule: the foreign code, `continue` so the base line
        /// still fires, and no routing attributes, which belong to the base line alone.
        /// The condition's alternatives of bare pairs, and the exact text they occupy —
        /// `(a=b | c=d) & rest` and the bare `a=b | c=d` alike. nil for any other
        /// shape: splitting is offered only where it is safe.
        func leadingGroup() -> (pairs: [String], span: String)? {
            // The alternatives end where actions or the type begin.
            let condition = text
            let cut = condition.firstIndex(of: "{") ?? condition.firstIndex(of: "[")
                ?? condition.endIndex
            var span = String(condition[..<cut])
            if span.hasPrefix("(") {
                guard let close = span.firstIndex(of: ")") else { return nil }
                span = String(span[...close])
            } else {
                span = span.trimmingCharacters(in: .whitespaces)
            }
            var inner = span
            if inner.hasPrefix("(") { inner = String(inner.dropFirst().dropLast()) }
            guard !inner.contains("(") else { return nil }
            var pairs: [String] = []
            for alternative in inner.split(separator: "|") {
                let pair = alternative.trimmingCharacters(in: .whitespaces)
                guard pair.range(of: "^[a-z_:]+=[a-z_0-9]+$",
                                 options: .regularExpression) != nil else { return nil }
                pairs.append(pair)
            }
            guard pairs.count > 1 else { return nil }
            return (pairs, span)
        }

        /// The rule with `& building!=*` added to its condition, so buildings fall
        /// through to the building rule. nil where alternatives are not bracketed:
        /// `a=b | c=d & building!=*` would narrow only the second.
        func narrowedToOpenGround() -> [String]? {
            let cut = text.firstIndex(of: "{") ?? text.firstIndex(of: "[") ?? text.endIndex
            let condition = text[..<cut].trimmingCharacters(in: .whitespaces)
            guard !condition.isEmpty, !condition.contains(DefaultRuleBook.buildingKey),
                  !condition.contains("|") || leadingGroup() != nil else { return nil }
            let rest = text[cut...]
            let narrowed = condition + " & " + DefaultRuleBook.openGroundOnly
                + (rest.isEmpty ? "" : " " + rest)
            return continuation.map { [narrowed, $0] } ?? [narrowed]
        }

        /// The head of a family condition, the `shop=*` of `shop=* & name=*`, or nil.
        func wildcardHead() -> String? {
            let head = text.prefix(while: { $0 != " " && $0 != "{" && $0 != "[" })
            return head.hasSuffix("=*") ? String(head) : nil
        }

        /// The rule rewritten around a subset of its alternatives and a new type, in as
        /// many lines as the original used: the whole replacement with the type swapped,
        /// its alternatives narrowed to the ones given.
        func replacementSplitting(group: [String], span: String, to type: Int)
            -> [String] {
            var lines = replacement(to: type)
            guard !lines.isEmpty else { return lines }
            let narrowed = "(" + group.joined(separator: " | ") + ")"
            lines[0] = lines[0].replacingOccurrences(of: span, with: narrowed)
            return lines
        }

        /// The rule rewritten with its wildcard head narrowed to one concrete pair, and
        /// the type swapped: the dedicated rule a family claimant earns above the family.
        func replacementDedicating(pair: String, to type: Int) -> [String] {
            guard let head = wildcardHead() else { return [] }
            var lines = replacement(to: type)
            guard !lines.isEmpty else { return lines }
            lines[0] = lines[0].replacingOccurrences(of: head, with: pair)
            return lines
        }

        func layered(to type: Int) -> String {
            var line = rewritten(to: type)
            for attribute in ["road_class", "road_speed"] {
                while let mark = line.range(of: "\(attribute)=") {
                    var end = mark.upperBound
                    while end < line.endIndex, line[end] != " ", line[end] != "]" {
                        end = line.index(after: end)
                    }
                    var from = mark.lowerBound
                    if from > line.startIndex, line[line.index(before: from)] == " " {
                        from = line.index(before: from)
                    }
                    line.removeSubrange(from..<end)
                }
            }
            guard !line.contains(" continue"), let close = line.lastIndex(of: "]") else {
                return line
            }
            line.insert(contentsOf: " continue", at: close)
            return line
        }
    }

    /// tag pair -> the rule lines it opens, per kind of element.
    private var byTag: [String: [Line]] = [:]
    /// The real files each kind's rules live in: the main file and its includes.
    private var filesOf: [String: Set<String>] = [:]
    /// The first rule line of each file, and the resolutions its rules use per tag key.
    /// Both serve writing a rule that does not exist yet: the line is the anchor, and the
    /// resolutions say at which zoom the style already draws things of that kind.
    private var firstRules: [String: [String]] = [:]
    private var resolutions: [String: [Int]] = [:]
    /// Every code the default rules emit, per file. A code found here is not foreign: the
    /// sheet must never rewrite a rule onto a code the set already uses.
    private var emitted: Set<String> = []

    /// The building tag, its value that says there is none, and the condition that
    /// keeps a rule off buildings.
    static let buildingKey = "building"
    static let noBuilding = "no"
    static let openGroundOnly = "building!=*"
    static let adminLevelKey = "admin_level"
    /// A relation's `type`: how it was assembled, not what it means.
    static let relationTypeKey = "type"

    /// The keys that carry meaning in OSM, the most telling first; bookkeeping keys carry
    /// none. A source usually carries several at once, so the fixed order picks the
    /// telling one, and picks the same one on every run.
    static let meaningKeys: [String] = [
        "highway", "railway", "aerialway", "aeroway", "waterway", "natural", "landuse",
        "leisure", "amenity", "shop", "tourism", "historic", "military", "power",
        "man_made", "barrier", "boundary", "place", "route", "water", "wetland",
        "piste:type", "sport", "office", "craft", "emergency", "healthcare",
        "leaf_type", "public_transport", "ford", "building",
    ]
    /// The same set, for asking whether a key means anything at all.
    static let meaningful = Set(meaningKeys)

    /// What one source is, as a single tag pair: the first meaning it carries.
    /// - Returns: nil where no key means anything, in which case it witnesses nothing.
    static func meaning(of tags: [String: String]) -> String? {
        for key in meaningKeys {
            if let value = tags[key], !value.isEmpty { return "\(key)=\(value)" }
        }
        return nil
    }

    static func load(from directory: URL = StyleCatalog.baseStyleDirectory) -> DefaultRuleBook {
        var book = DefaultRuleBook()
        for file in ["lines", "polygons", "points"] {
            guard let text = try? String(contentsOf: directory.appendingPathComponent(file),
                                         encoding: .utf8) else { continue }
            // The main file pulls parts of itself from inc/; the book reads them as the
            // build does, or every rule living there looks foreign to its own map. A
            // line keeps its real path, so a sheet substitution lands in the right file.
            var sources: [(name: String, text: String)] = [(file, text)]
            for row in text.components(separatedBy: "\n") {
                let trimmed = row.trimmingCharacters(in: .whitespaces)
                guard trimmed.hasPrefix("include '"),
                      let close = trimmed.dropFirst(9).firstIndex(of: "'") else { continue }
                let name = String(trimmed.dropFirst(9)[..<close])
                guard let sub = try? String(
                    contentsOf: directory.appendingPathComponent(name),
                    encoding: .utf8) else { continue }
                sources.append((name, sub))
            }
            for (name, text) in sources {
                book.read(name: name, kindFile: file, text: text)
            }
        }
        return book
    }

    /// Reads one rule file into the book. `kindFile` is the including file — what the
    /// code is emitted *as* — and `name` the file the lines actually live in.
    private mutating func read(name: String, kindFile file: String, text: String) {
        filesOf[file, default: []].insert(name)
            // The emitted-code set reads every rule, split-line ones included: a rule
            // carrying its type on its own line would otherwise look foreign.
            for rule in ZoomRuleScan.rules(in: text.components(separatedBy: "\n")) {
                if let open = rule.type.range(of: "0x"),
                   let value = Int(rule.type[open.upperBound...].prefix(while: \.isHexDigit),
                                   radix: 16) {
                    emitted.insert(file + ":" + String(value, radix: 16))
                }
            }
            // Raw lines, because the sheet substitutes raw lines.
            let rows = text.components(separatedBy: "\n")
            // How often each line reads exactly the same, so a two-line rule is anchored
            // on its type line only where that line is unique in the file.
            var seen: [String: Int] = [:]
            for row in rows {
                seen[row.trimmingCharacters(in: .whitespaces), default: 0] += 1
            }
            var pendingCondition: String?
            for raw in rows {
                let trimmed = raw.trimmingCharacters(in: .whitespaces)
                guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else {
                    pendingCondition = nil
                    continue
                }
                // A condition with no type of its own: the type is on the next line.
                guard let open = trimmed.firstIndex(of: "[") else {
                    pendingCondition = trimmed.contains("=") ? trimmed : nil
                    continue
                }
                // The type line of a two-line rule may open with actions of its own, as in
                // `{add name='${barrier}'} [0x3200 resolution 24]`; reading those as a
                // condition would index the rule under nothing.
                let before = Self.withoutActions(String(trimmed[..<open]))
                    .trimmingCharacters(in: .whitespaces)
                let onItsOwn = before.isEmpty
                let condition = onItsOwn ? (pendingCondition ?? "") : String(trimmed[..<open])
                pendingCondition = nil
                guard condition.contains("=") else { continue }
                // The two-line form is anchored on its condition, which has to be the only
                // line of its kind for the substitution to name one rule.
                if onItsOwn, seen[condition] != 1 { continue }
                guard let line = onItsOwn
                    ? Line(file: name, text: condition, continuation: raw)
                    : Line(file: name, text: trimmed) else { continue }
                // Indexed under its LEADING tag pair: the discriminating one, the way
                // rules are written. `landuse=forest | landuse=wood` indexes under both.
                emitted.insert(file + ":" + line.code)
                if name == file, (firstRules[file]?.count ?? 0) < 64 {
                    firstRules[file, default: []].append(line.text)
                }
                let resolution = Self.resolution(of: onItsOwn ? trimmed : line.text)
                for pair in Self.leadingPairs(of: condition) {
                    byTag[pair, default: []].append(line)
                    if let resolution, let key = pair.split(separator: "=").first {
                        resolutions[file + ":" + key, default: []].append(resolution)
                    }
                }
            }
    }

    /// Every rule line the book indexed for one kind — the main file and its includes —
    /// one entry per rule, in a settled order: what the silencing pass walks.
    func allLines(forKind kindFile: String) -> [Line] {
        let files = filesOf[kindFile] ?? [kindFile]
        var seen = Set<String>()
        var out: [Line] = []
        for lines in byTag.values {
            for line in lines where files.contains(line.file) {
                if seen.insert(line.file + ":" + line.text).inserted { out.append(line) }
            }
        }
        return out.sorted { ($0.file, $0.text) < ($1.file, $1.text) }
    }

    /// Whether any rule of this kind is indexed under a pair of this key.
    func hasRules(key: String, kind: ElementDumper.Kind) -> Bool {
        let files = filesOf[Self.file(for: kind)] ?? [Self.file(for: kind)]
        let prefix = key + "="
        return byTag.contains { pair, lines in
            pair.hasPrefix(prefix) && lines.contains { files.contains($0.file) }
        }
    }

    /// Whether the default set already emits this code for this kind of element.
    func alreadyEmits(_ type: Int, kind: ElementDumper.Kind) -> Bool {
        emitted.contains(file(for: kind) + ":" + String(type, radix: 16))
    }

    static func file(for kind: ElementDumper.Kind) -> String {
        switch kind {
        case .point: return "points"
        case .line: return "lines"
        case .area: return "polygons"
        }
    }
    private func file(for kind: ElementDumper.Kind) -> String { Self.file(for: kind) }

    /// The `resolution N` a rule line asks for, when it names one.
    static func resolution(of text: String) -> Int? {
        guard let at = text.range(of: "resolution ") else { return nil }
        return Int(text[at.upperBound...].prefix(while: \.isNumber))
    }

    /// The line a rule that does not exist yet is written above: the file's first rule, so
    /// a new rule is reached before the general ones.
    /// - Parameter avoiding: lines the sheet already rewrites; two substitutions naming
    ///   one line would leave the second unable to find it.
    func firstRuleLine(in file: String, avoiding taken: Set<String> = []) -> String? {
        (firstRules[file] ?? []).first { !taken.contains($0) }
    }

    /// The zoom a new rule should carry: the one the style most often draws that tag key
    /// at, falling back to the level the smallest features are drawn at.
    func typicalResolution(forKey key: String, kind: ElementDumper.Kind) -> Int {
        let known = resolutions[file(for: kind) + ":" + key] ?? []
        guard !known.isEmpty else { return kind == .point ? 24 : 22 }
        var counts: [Int: Int] = [:]
        for value in known { counts[value, default: 0] += 1 }
        return counts.max { ($0.value, -$0.key) < ($1.value, -$1.key) }?.key ?? 22
    }

    func lines(for tag: String, kind: ElementDumper.Kind) -> [Line]? {
        let files = filesOf[Self.file(for: kind)] ?? [Self.file(for: kind)]
        var hits = (byTag[tag] ?? []).filter { files.contains($0.file) }
        // A family rule — `building=* & building!=no` — draws every value of its key,
        // so a tag with no rule of its own is still drawn, by the family. Only as a
        // fallback: a tag with rules of its own is theirs, and pulling the family in
        // would hand every claim on the tag a family-wide rewrite.
        if hits.isEmpty, let key = tag.split(separator: "=").first {
            hits = (byTag["\(key)=*"] ?? []).filter { files.contains($0.file) }
        }
        return hits.isEmpty ? nil : hits
    }

    /// A rule's condition without the actions it carries: in `natural=cliff {name
    /// '${name}'}`, the braces are not part of the tag's value.
    static func withoutActions(_ condition: String) -> String {
        var out = ""
        var depth = 0
        for c in condition {
            if c == "{" { depth += 1 } else if c == "}" { depth = max(0, depth - 1) }
            else if depth == 0 { out.append(c) }
        }
        return out
    }

    /// `landuse=forest | landuse=wood & foo=bar` -> ["landuse=forest", "landuse=wood"].
    /// Only the alternatives' first pairs: the rest of a condition narrows, not names.
    static func leadingPairs(of condition: String) -> [String] {
        var out: [String] = []
        for alternative in withoutActions(condition).split(separator: "|") {
            let head = alternative.split(separator: "&").first ?? ""
            let pair = head.trimmingCharacters(in: CharacterSet(charactersIn: " ()"))
            guard let eq = pair.firstIndex(of: "="), !pair.hasPrefix("mkgmap:") else { continue }
            let key = String(pair[..<eq])
            let value = String(pair[pair.index(after: eq)...])
            guard meaningful.contains(key), !value.isEmpty,
                  !value.contains("!") else { continue }
            // A bare `key=*` is a family rule and is indexed as one; a value merely
            // containing a wildcard names nothing and is skipped.
            if value.contains("*") {
                if value == "*" { out.append("\(key)=*") }
                continue
            }
            out.append("\(key)=\(value)")
        }
        return out
    }
}
