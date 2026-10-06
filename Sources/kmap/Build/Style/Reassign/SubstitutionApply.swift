import Foundation

/// A substitution sheet applied to a materialized style, line for exact line.
extension StyleCatalog {
    /// Applies a substitution list - the `@@ file` / `- old` / `+ new` format shared by
    /// `redirects.txt` and `reassignments.txt` - to a materialized style. Matching is
    /// exact-line: a substitution that no longer matches is reported, not applied loosely.
    @discardableResult

    static func applySubstitutions(
        _ list: String,
        in directory: URL
    ) throws -> (applied: Int, missed: [String], hidden: Int) {
        var edits: [String: [(old: String, new: [String])]] = [:]
        for entry in SubstitutionSheet.parse(list) where !entry.file.isEmpty {
            edits[entry.file, default: []].append((entry.old.joined(separator: "\n"), entry.new))
        }

        var applied = 0
        var missed: [String] = []
        var hidden = 0
        for (name, substitutions) in edits {
            let url = directory.appendingPathComponent(name)
            guard var text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            for substitution in substitutions {
                guard text.contains(substitution.old) else {
                    // The hide pass rewrites a rule's type line and leaves its mark; a
                    // substitution aimed at a hidden rule has nothing to retarget - the
                    // rule draws nothing - so the miss is bookkeeping, not a warning.
                    if Self.isHidden(substitution.old, in: text) {
                        hidden += 1
                        continue
                    }
                    // A name literal the language pass rewrote does not unmake the rule:
                    // the same condition carrying the same type is the same rule, and
                    // only its type token is swapped.
                    if Self.retype(
                        &text,
                        old: substitution.old,
                        new: substitution.new.joined(separator: "\n")
                    ) {
                        applied += 1
                    } else {
                        missed.append("\(name): \(truncate(substitution.old, to: 60))")
                    }
                    continue
                }
                text = text.replacingOccurrences(
                    of: substitution.old,
                    with: substitution.new.joined(separator: "\n")
                )
                applied += 1
            }
            try FileTools.write(text, to: url)
        }
        return (applied, missed, hidden)
    }

    /// Whether the hide pass took the type from the rule `old` names: its own first line
    /// carries the hidden mark, not a comment or another rule quoting it.
    static func isHidden(_ old: String, in text: String) -> Bool {
        // The condition alone: a hidden rule keeps its actions with deletes added.
        func bare(_ line: String) -> String {
            let upTo = line.components(separatedBy: " [0x").first ?? line
            return (upTo.components(separatedBy: "{").first ?? upTo).trimmingCharacters(in: .whitespaces)
        }
        let first = (old.components(separatedBy: "\n").first ?? old)
        let condition = bare(first)
        guard !condition.isEmpty else { return false }
        let lines = text.components(separatedBy: "\n")
        for (at, line) in lines.enumerated() {
            // Commented out whole, or kept with its actions and its type dropped.
            let body = String(line.trimmingCharacters(in: .whitespaces).drop { $0 == "#" || $0 == " " })
            // The whole condition, not its start: `shop=car` is not `shop=car_repair`.
            let head = bare(body.components(separatedBy: "# kmap:").first ?? body)
            guard head == condition else { continue }
            let rule = lines[at..<min(lines.count, at + old.components(separatedBy: "\n").count)]
            if rule.contains(where: { $0.contains("# kmap: hidden") }) { return true }
        }
        return false
    }

    /// The language-proof fallback for a substitution. A sheet is derived against the
    /// pristine rules (English labels, nothing moved by a zoom plan) but applied to this
    /// build's, where a ford's label may be Russian and a rule may sit at another resolution.
    /// Exact-line matching misses such a rule, so it is found by what cannot drift: the bare
    /// condition and the type it emits.
    ///
    /// 3 shapes are honoured: a rule deleted, a rule re-aimed, and a rule kept with strokes
    /// stacked above it. Anything else is left to the exact match, and reported when that
    /// misses.
    private static func retype(_ text: inout String, old: String, new: String) -> Bool {
        func token(of rule: String) -> Substring? {
            guard let open = rule.range(of: "[0x") else { return nil }
            return rule[open.lowerBound...].prefix(while: { $0 != " " && $0 != "]" })
        }
        func bareCondition(of rule: String) -> String? {
            let first = rule.split(separator: "\n").first.map(String.init) ?? rule
            let cut =
                first.firstIndex(of: "{") ?? first.firstIndex(of: "[")
                ?? first.endIndex
            let condition = String(first[..<cut]).trimmingCharacters(in: .whitespaces)
            return condition.isEmpty ? nil : condition
        }
        guard let oldToken = token(of: old), let condition = bareCondition(of: old)
        else { return false }

        let oldLines = old.components(separatedBy: "\n")
        let newLines = new.isEmpty ? [] : new.components(separatedBy: "\n")
        // Every replacement line must be about the same rule, or this substitution is
        // doing more than the fallback understands.
        // A line that is the type alone is the second line of a 2-line rule.
        guard
            newLines.allSatisfy({ line in
                guard line.contains("[0x") else { return true }
                return line.trimmingCharacters(in: .whitespaces).hasPrefix("[")
                    || bareCondition(of: line) == condition
            })
        else { return false }

        var lines = text.components(separatedBy: "\n")
        for at in lines.indices {
            // The whole condition, not a prefix: `highway=motorway` must not land on
            // `highway=motorway & mkgmap:fast_road=yes`.
            guard
                bareCondition(
                    of: lines[at]
                        .trimmingCharacters(in: .whitespaces)
                ) == condition
            else { continue }
            // The type may sit on this line or, for a 2-line rule, on the next.
            guard
                let target = [at, at + 1].first(where: {
                    $0 < lines.count && lines[$0].contains(oldToken)
                })
            else { continue }

            // The rule's own resolution here and now: an unbanded stroke follows it, so
            // the stack appears and vanishes as one.
            let here = lines[target].range(
                of: "resolution [0-9-]+",
                options: .regularExpression
            )
            .map { String(lines[target][$0]) }
            func fitted(_ line: String) -> String {
                // A stroke is paint, not meaning: the name belongs to the rule below
                // it, which sets it whatever language this build speaks. A label
                // carried up from the sheet would be the untranslated one.
                //
                // The block is taken by hand rather than by pattern: `${name}` puts a
                // closing brace inside it, and a lazy match ends there.
                var out = line
                if let open = out.firstIndex(of: "{"),
                    let type = out.range(of: "[0x"),
                    let close = out[open..<type.lowerBound].lastIndex(of: "}")
                {
                    let block = open...close
                    let kept = out[block].dropFirst().dropLast()
                        .split(separator: ";")
                        .map { $0.trimmingCharacters(in: .whitespaces) }
                        .filter {
                            !$0.hasPrefix("name ") && !$0.hasPrefix("add name")
                                && !$0.hasPrefix("set name")
                        }
                    out = out.replacingCharacters(
                        in: block,
                        with: kept.isEmpty ? "" : "{" + kept.joined(separator: "; ") + "}"
                    )
                    while out.contains("  ") {
                        out = out.replacingOccurrences(of: "  ", with: " ")
                    }
                }
                // A stroke pinned to a band of zooms keeps it: the band is where that
                // stroke belongs, and the rule's own resolution says nothing about it.
                guard let here,
                    out.range(
                        of: "resolution [0-9]+-[0-9]+",
                        options: .regularExpression
                    ) == nil
                else { return out }
                return out.replacingOccurrences(
                    of: "resolution [0-9-]+",
                    with: here,
                    options: .regularExpression
                )
            }

            guard !newLines.isEmpty else {
                // Silenced: the rule and its second line go.
                lines.removeSubrange(at...(min(target, lines.count - 1)))
                text = lines.joined(separator: "\n")
                return true
            }
            // The last replacement line is the rule itself, re-aimed or unchanged; the
            // ones before it are strokes stacked above.
            guard let closing = newLines.last, let newToken = token(of: closing)
            else { return false }
            // The rule's own lines, 1 or 2, end the replacement.
            let layers = newLines.dropLast(oldLines.count).map(fitted)
            lines[target] = lines[target].replacingOccurrences(
                of: String(oldToken),
                with: String(newToken)
            )
            // A rule the sheet has pinned to a band takes that band: the strokes above
            // it own the other zooms, and leaving its own `resolution N` - which means
            // N and every zoom finer - would draw it under each of them as well, a
            // river once in its own colour and again in the stroke's. Never coarser
            // than this build already draws the rule: the zoom plan has had its say.
            if let band = closing.range(
                of: "resolution [0-9]+-[0-9]+",
                options: .regularExpression
            ),
                lines[target].range(
                    of: "resolution [0-9]+-[0-9]+",
                    options: .regularExpression
                ) == nil
            {
                let edges = closing[band].split(separator: " ")[1].split(separator: "-")
                let own = here.flatMap { Int($0.split(separator: " ")[1]) }
                if edges.count == 2, let low = Int(edges[0]), let high = Int(edges[1]),
                    max(low, own ?? low) <= high
                {
                    lines[target] = lines[target].replacingOccurrences(
                        of: "resolution [0-9-]+",
                        with: "resolution \(max(low, own ?? low))-\(high)",
                        options: .regularExpression
                    )
                }
            }
            // Above the rule, which stops the chain: a stroke pinned to a band does
            // not match outside it, and a rule left looking would run on into whatever
            // the rules below draw.
            if !layers.isEmpty { lines.insert(contentsOf: layers, at: at) }
            text = lines.joined(separator: "\n")
            return true
        }
        return false
    }
}
