import Foundation

extension StyleCatalog {
    /// The `@@ file` / `- old` / `+ new` format of `redirects.txt` and `reassignments.txt`.
    /// Matching is exact-line: a substitution that no longer matches is reported, not
    /// applied loosely.
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
                    // The hide pass rewrote this rule's type line; a hidden rule draws nothing,
                    // so the miss is bookkeeping, not a warning.
                    if Self.isHidden(substitution.old, in: text) {
                        hidden += 1
                        continue
                    }
                    // The language pass may have rewritten a name literal: the same
                    // condition with the same type is the same rule, so only the type swaps.
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

    /// The rule's own lines must carry the hidden mark, not a comment or another rule
    /// quoting it.
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

    /// A sheet is derived against pristine rules but applied to this build's, where labels
    /// and resolutions may differ, so the rule is found by its bare condition and type.
    /// Handles a rule deleted, re-aimed, or kept with strokes stacked above; anything else
    /// is left to the exact match and reported.
    private static func retype(_ text: inout String, old: String, new: String) -> Bool {
        guard let oldToken = ruleToken(of: old), let condition = bareCondition(of: old)
        else { return false }

        let oldLines = old.components(separatedBy: "\n")
        let newLines = new.isEmpty ? [] : new.components(separatedBy: "\n")
        // Every replacement line must be about the same rule, or this fallback does not
        // understand it. A line with the type alone is the second line of a 2-line rule.
        guard
            newLines.allSatisfy({ line in
                guard line.contains("[0x") else { return true }
                return line.trimmingCharacters(in: .whitespaces).hasPrefix("[")
                    || bareCondition(of: line) == condition
            })
        else { return false }

        var lines = text.components(separatedBy: "\n")
        for at in lines.indices {
            // The whole condition: `highway=motorway` must not land on
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

            // An unbanded stroke takes the rule's resolution, so the stack shows as one.
            let here = lines[target].range(
                of: "resolution [0-9-]+",
                options: .regularExpression
            )
            .map { String(lines[target][$0]) }

            guard !newLines.isEmpty else {
                // Silenced: the rule and its second line go.
                lines.removeSubrange(at...(min(target, lines.count - 1)))
                text = lines.joined(separator: "\n")
                return true
            }
            // The last line is the rule itself; the ones before it are strokes above.
            guard let closing = newLines.last, let newToken = ruleToken(of: closing)
            else { return false }
            // The rule's own lines, 1 or 2, end the replacement.
            let layers = newLines.dropLast(oldLines.count).map { fittedStroke($0, resolution: here) }
            lines[target] = lines[target].replacingOccurrences(
                of: String(oldToken),
                with: String(newToken)
            )
            // The strokes own the other zooms; `resolution N` means N and finer, so the rule
            // left at it would draw a river twice, in its own colour and the stroke's.
            pinToBand(&lines[target], as: closing, resolution: here)
            // Above the rule, which stops the chain; otherwise a banded stroke would fall
            // through outside its band into the rules below.
            if !layers.isEmpty { lines.insert(contentsOf: layers, at: at) }
            text = lines.joined(separator: "\n")
            return true
        }
        return false
    }

    /// `[0x2f` without the rest.
    static func ruleToken(of rule: String) -> Substring? {
        guard let open = rule.range(of: "[0x") else { return nil }
        return rule[open.lowerBound...].prefix(while: { $0 != " " && $0 != "]" })
    }

    static func bareCondition(of rule: String) -> String? {
        let first = rule.split(separator: "\n").first.map(String.init) ?? rule
        let cut =
            first.firstIndex(of: "{") ?? first.firstIndex(of: "[")
            ?? first.endIndex
        let condition = String(first[..<cut]).trimmingCharacters(in: .whitespaces)
        return condition.isEmpty ? nil : condition
    }

    /// Drops the name, which the rule below sets in this build's language, and gives the
    /// rule's resolution `here` unless the stroke is pinned to a band of its own.
    static func fittedStroke(_ line: String, resolution here: String?) -> String {
        // Not by pattern: `${name}` puts a closing brace inside the block.
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

    /// Never coarser than this build already draws it (`here`): the zoom plan has its say.
    static func pinToBand(_ line: inout String, as closing: String, resolution here: String?) {
        if let band = closing.range(
            of: "resolution [0-9]+-[0-9]+",
            options: .regularExpression
        ),
            line.range(
                of: "resolution [0-9]+-[0-9]+",
                options: .regularExpression
            ) == nil
        {
            let edges = closing[band].split(separator: " ")[1].split(separator: "-")
            let own = here.flatMap { Int($0.split(separator: " ")[1]) }
            if edges.count == 2, let low = Int(edges[0]), let high = Int(edges[1]),
                max(low, own ?? low) <= high
            {
                line = line.replacingOccurrences(
                    of: "resolution [0-9-]+",
                    with: "resolution \(max(low, own ?? low))-\(high)",
                    options: .regularExpression
                )
            }
        }
    }
}
