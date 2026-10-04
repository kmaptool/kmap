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
}
