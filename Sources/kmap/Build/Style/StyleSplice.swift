import Foundation

/// The build choices a style is materialized with. One value travels through the whole
/// materialization instead of four loose parameters.
struct StyleChoices {
    var descriptions: BuildRecipe.DescriptionCarrier = .off
    var hidden: Set<String> = []
    var zoom: (plan: ZoomPlan, levels: LevelsProfile) = (.asMeasured, .smooth)
    var cyrillic = false
}

/// How every kmap rule block lands in a materialized rule file. Three placements cover
/// them all, and each is guarded by the block's marker line so a directory is amended
/// once and only once.
extension StyleCatalog {

    /// Where an anchored insertion ended up, so the caller can warn when the stock rule
    /// it aims at has changed in this mkgmap.
    enum RuleInsertion {
        case added
        /// The marker is already in the file, or the style has no such file — either way
        /// there is nothing to do and nothing to say.
        case leftAlone
        case missingAnchor
    }

    /// Rewrites one rule file in place. A style without the file, or one already carrying
    /// `marker`, is left alone; the file is written back only when `change` says it
    /// touched the text.
    func amendRuleFile(_ name: String, in directory: URL, unlessMarked marker: String? = nil,
                       change: (inout String) -> Bool) throws {
        let url = directory.appendingPathComponent(name)
        guard var text = try? String(contentsOf: url, encoding: .utf8) else { return }
        if let marker, text.contains(marker) { return }
        guard change(&text) else { return }
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    /// Splices a marked block ahead of `<finalize>`, once.
    ///
    /// - Returns: true when the block went in, so the caller logs only what happened.
    @discardableResult
    func spliceRules(_ rules: String, marked marker: String, intoFile name: String,
                     in directory: URL) throws -> Bool {
        var added = false
        try amendRuleFile(name, in: directory, unlessMarked: marker) { text in
            splice(rules, into: &text)
            added = true
            return true
        }
        return added
    }

    /// Puts a marked block at the very top of the file: for action-only rules that must
    /// run before every stock rule, and for the repair link, which a stock rule below
    /// would otherwise claim first.
    @discardableResult
    func prependRules(_ rules: String, marked marker: String, toFile name: String,
                      in directory: URL) throws -> Bool {
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
    func insertRules(_ rules: String, marked marker: String, beforeLineWith anchor: String,
                     intoFile name: String, in directory: URL) throws -> RuleInsertion {
        var outcome = RuleInsertion.leftAlone
        try amendRuleFile(name, in: directory, unlessMarked: marker) { text in
            guard let hit = text.range(of: anchor) else {
                outcome = .missingAnchor
                return false
            }
            let lineStart = text.range(of: "\n", options: .backwards,
                                       range: text.startIndex..<hit.lowerBound)?.upperBound
                ?? text.startIndex
            text.replaceSubrange(lineStart..<lineStart, with: rules)
            outcome = .added
            return true
        }
        return outcome
    }
}
