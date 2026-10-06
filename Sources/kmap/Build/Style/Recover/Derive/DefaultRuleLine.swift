import Foundation

extension DefaultRuleBook {
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
            let width =
                carrier.distance(
                    from: typeRange.lowerBound,
                    to: typeRange.upperBound
                ) - 2
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
        /// The condition's alternatives of bare pairs, and the exact text they occupy -
        /// `(a=b | c=d) & rest` and the bare `a=b | c=d` alike. nil for any other
        /// shape: splitting is offered only where it is safe.
        func leadingGroup() -> (pairs: [String], span: String)? {
            // The alternatives end where actions or the type begin.
            let condition = text
            let cut =
                condition.firstIndex(of: "{") ?? condition.firstIndex(of: "[")
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
                guard
                    pair.range(
                        of: "^[a-z_:]+=[a-z_0-9]+$",
                        options: .regularExpression
                    ) != nil
                else { return nil }
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
                !condition.contains("|") || leadingGroup() != nil
            else { return nil }
            let rest = text[cut...]
            let narrowed =
                condition + " & " + DefaultRuleBook.openGroundOnly
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
        func replacementSplitting(
            group: [String],
            span: String,
            to type: Int
        ) -> [String] {
            var lines = replacement(to: type)
            guard !lines.isEmpty else { return lines }
            let narrowed = "(" + group.joined(separator: " | ") + ")"
            lines[0] = lines[0].replacingOccurrences(of: span, with: narrowed)
            return lines
        }

        /// The rule rewritten with its wildcard head narrowed to one concrete pair, and
        /// the type swapped: the dedicated rule a family claimant earns above the family.
        func replacementDedicating(pair: String, to type: Int) -> [String] {
            guard let head = wildcardHead(), let condition = DefaultRuleBook.condition(pair) else { return [] }
            var lines = replacement(to: type)
            guard !lines.isEmpty else { return lines }
            lines[0] = lines[0].replacingOccurrences(of: head, with: condition)
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

        /// Whether the rule's condition holds for these tags; nil where it is more than
        /// plain terms joined by `&`, or names a tag mkgmap makes itself.
        func holds(for tags: [String: String]) -> Bool? {
            let condition = DefaultRuleBook.withoutActions(String(text.prefix { $0 != "[" }))
            guard !condition.contains(where: { "|()~".contains($0) }) else { return nil }
            for raw in condition.split(separator: "&") {
                let term = raw.trimmingCharacters(in: .whitespaces)
                guard let held = Self.holds(term, for: tags) else { return nil }
                if !held { return false }
            }
            return true
        }

        /// One term: `k=v`, `k=*`, `k!=v`, `k!=*`, or a number compared with `<`, `<=`,
        /// `>` or `>=` by the first number in the value; a value with none fails, as in
        /// mkgmap.
        private static func holds(_ term: String, for tags: [String: String]) -> Bool? {
            for op in ["!=", ">=", "<=", "=", ">", "<"] {
                guard let at = term.range(of: op) else { continue }
                let key = term[..<at.lowerBound].trimmingCharacters(in: .whitespaces)
                var value = term[at.upperBound...].trimmingCharacters(in: .whitespaces)
                if value.count >= 2, let first = value.first, "'\"".contains(first), value.last == first {
                    value = String(value.dropFirst().dropLast())
                }
                guard !key.isEmpty, !key.hasPrefix("mkgmap:") else { return nil }
                let have = tags[key]
                switch op {
                case "=": return value == "*" ? have != nil : have == value
                case "!=": return value == "*" ? have == nil : have != value
                default:
                    guard let limit = Double(value) else { return nil }
                    guard let number = have.flatMap(Self.leadingNumber) else { return false }
                    switch op {
                    case ">": return number > limit
                    case ">=": return number >= limit
                    case "<": return number < limit
                    default: return number <= limit
                    }
                }
            }
            return nil
        }

        /// The first number in a value, as mkgmap finds one: `75000 (2010)` and `~75000`
        /// are 75000; a run of digits and dots that is no number, as in `c. 75000`, is none.
        private static func leadingNumber(_ value: String) -> Double? {
            let chars = Array(value)
            func part(_ c: Character) -> Bool { c.isASCII && (c.isNumber || c == ".") }
            guard
                var at = chars.indices.first(where: {
                    part(chars[$0]) || (chars[$0] == "-" && $0 + 1 < chars.count && part(chars[$0 + 1]))
                })
            else { return nil }
            let from = at
            if chars[at] == "-" { at += 1 }
            while at < chars.count, part(chars[at]) { at += 1 }
            return Double(String(chars[from..<at]))
        }
    }
}
