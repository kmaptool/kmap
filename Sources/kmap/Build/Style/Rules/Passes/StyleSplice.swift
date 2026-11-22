import Foundation

/// How every kmap rule block lands in a materialized rule file. 4 placements cover
/// them all, and each is guarded by the block's marker line so a directory is amended
/// once and only once.
extension StyleCatalog {
    /// Where an anchored insertion ended up, so the caller can warn when the stock rule
    /// it aims at has changed in this mkgmap.
    enum RuleInsertion {
        case added
        /// The marker is already in the file, or the style has no such file - either way
        /// there is nothing to do and nothing to say.
        case leftAlone
        case missingAnchor
    }

    /// Rewrites one rule file in place. A style without the file, or one already carrying
    /// `marker`, is left alone; the file is written back only when `change` says it
    /// touched the text.
    func amendRuleFile(
        _ name: String,
        in directory: URL,
        unlessMarked marker: String? = nil,
        change: (inout String) -> Bool
    ) throws {
        let url = directory.appendingPathComponent(name)
        guard var text = try? String(contentsOf: url, encoding: .utf8) else { return }
        if let marker, text.contains(marker) { return }
        guard change(&text) else { return }
        try FileTools.write(text, to: url)
    }

    /// Splices a marked block ahead of `<finalize>`, once.
    ///
    /// - Returns: true when the block went in, so the caller logs only what happened.
    @discardableResult
    func spliceRules(
        _ rules: String,
        marked marker: String,
        intoFile name: String,
        in directory: URL
    ) throws -> Bool {
        var added = false
        try amendRuleFile(name, in: directory, unlessMarked: marker) { text in
            splice(rules, into: &text)
            added = true
            return true
        }
        return added
    }

    /// Splices a marked block ahead of the stock rule that answers for every value of
    /// `key`: that rule would claim these first, and the first match wins. Ahead of
    /// `<finalize>` where the style has no such rule.
    @discardableResult
    func spliceRules(
        _ rules: String,
        marked marker: String,
        aheadOfEvery key: String,
        intoFile name: String,
        in directory: URL
    ) throws -> Bool {
        var added = false
        try amendRuleFile(name, in: directory, unlessMarked: marker) { text in
            if let at = Self.catchAll(for: key, in: text) {
                // Set apart from a rule standing right above.
                let apart = at == text.startIndex || text[..<at].hasSuffix("\n\n") ? "" : "\n"
                text.insert(contentsOf: apart + rules.trimmingCharacters(in: .newlines) + "\n\n", at: at)
            } else {
                splice("\n\n" + rules.trimmingCharacters(in: .newlines) + "\n", into: &text)
            }
            added = true
            return true
        }
        return added
    }

    /// Where the stock rule for every value of `key` starts, the comment above it
    /// included: `key=* & ...` or `key=* | ...` drawn with a type and no `continue`,
    /// narrowed by nothing but negations of a value and the shape of the way. nil
    /// where the file has none.
    static func catchAll(for key: String, in text: String) -> String.Index? {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        for (number, line) in lines.enumerated() where line.hasPrefix(key + "=*") {
            // mkgmap writes a long rule over several lines, the later ones indented.
            var rule = String(line)
            var next = number + 1
            while !rule.contains("[0x"), next < lines.count, lines[next].first?.isWhitespace == true,
                !lines[next].trimmingCharacters(in: .whitespaces).isEmpty
            {
                rule += " " + lines[next]
                next += 1
            }
            guard let type = rule.range(of: "[0x"), let close = rule[type.lowerBound...].firstIndex(of: "]"),
                !rule[type.lowerBound..<close].contains(" continue")
            else { continue }
            // The action block ends where the type begins, whatever braces it holds.
            var condition = String(rule[..<type.lowerBound])
            if let open = condition.firstIndex(of: "{") { condition = String(condition[..<open]) }
            let rest = condition.dropFirst(key.count + 2).trimmingCharacters(in: .whitespaces)
            // An alternative only widens it: every value of the key is still answered.
            if !rest.hasPrefix("|") {
                let narrowed = rest.replacingOccurrences(of: "[a-z_:]+!=[^ )]+", with: "", options: .regularExpression)
                guard !narrowed.contains("~"), !narrowed.contains("<"), !narrowed.contains(">"),
                    !narrowed.contains("!(")
                else { continue }
                let tested = narrowed.allMatches("[a-z_:]+=").map { String($0.dropLast()) }
                guard tested.allSatisfy({ $0 == key || $0 == "area" || $0 == "mkgmap:mp_created" }) else { continue }
            }
            var first = number
            while first > 0, lines[first - 1].hasPrefix("#") { first -= 1 }
            return lines[first].startIndex
        }
        return nil
    }

    /// Puts a marked block at the very top of the file: for action-only rules that must
    /// run before every stock rule, and for the repair link, which a stock rule below
    /// would otherwise claim first.
    @discardableResult
    func prependRules(
        _ rules: String,
        marked marker: String,
        toFile name: String,
        in directory: URL
    ) throws -> Bool {
        var added = false
        try amendRuleFile(name, in: directory, unlessMarked: marker) { text in
            text = rules + text
            added = true
            return true
        }
        return added
    }

    /// Inserts a block at the start of the line holding `anchor`: for rules that must
    /// precede one stock rule exactly, because the first match wins.
    ///
    /// The text goes in verbatim, so the caller shapes its own trailing newlines.
    func insertRules(
        _ rules: String,
        marked marker: String,
        beforeLineWith anchor: String,
        intoFile name: String,
        in directory: URL
    ) throws -> RuleInsertion {
        var outcome = RuleInsertion.leftAlone
        try amendRuleFile(name, in: directory, unlessMarked: marker) { text in
            guard let hit = text.range(of: anchor) else {
                outcome = .missingAnchor
                return false
            }
            let lineStart =
                text.range(
                    of: "\n",
                    options: .backwards,
                    range: text.startIndex..<hit.lowerBound
                )?.upperBound
                ?? text.startIndex
            text.replaceSubrange(lineStart..<lineStart, with: rules)
            outcome = .added
            return true
        }
        return outcome
    }
}
