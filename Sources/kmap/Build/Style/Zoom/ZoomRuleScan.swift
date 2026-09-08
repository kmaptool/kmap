import Foundation

/// Reads a style's rule file as rules rather than as lines.
///
/// A rule may span two lines, the condition on one and `[0x14 resolution 22]` on the next,
/// or three, with an action block sharing the type's line:
///
///     waterway=* & waterway!=no & (area=no | …)
///         {add name='${waterway|subst:"_=> "}'} [0x26 resolution 24]
///
/// Both the survey and the rewriting pass read through this, so they cannot diverge.
struct ZoomRuleScan {
    /// A rule with a type in it: which line the type is on, and which condition owns it.
    struct Rule {
        let line: Int
        let condition: String
        /// The `[…]` including its brackets.
        let type: String
        /// Where the type sits in that line.
        let typeRange: Range<String.Index>
    }

    /// Every typed rule in `lines`, in order.
    static func rules(in lines: [String]) -> [Rule] {
        var out: [Rule] = []
        // The last condition seen with no type after it, waiting for its type.
        var pending: String?

        for (i, line) in lines.enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") {
                // A blank line or a comment ends a continuation: mkgmap allows neither
                // inside a rule.
                pending = nil
                continue
            }
            guard let open = line.firstIndex(of: "["),
                  let close = line[open...].firstIndex(of: "]") else {
                // No type: a condition awaiting one on a later line, unless it is an
                // `include`, a `<finalize>` marker or a standalone action block.
                pending = trimmed.hasSuffix(";") || trimmed.hasPrefix("<")
                    || trimmed.hasPrefix("include") ? nil : line
                continue
            }
            var ahead = String(line[line.startIndex..<open]).trimmingCharacters(in: .whitespaces)
            // An action block is not a condition: on a three-line rule it shares the type's
            // line, and reading it as the condition would name the wrong tag.
            if ahead.hasPrefix("{") { ahead = "" }
            let condition = ahead.isEmpty ? (pending ?? "") : ahead
            pending = nil
            guard !condition.isEmpty else { continue }
            out.append(Rule(line: i, condition: condition,
                            type: String(line[open...close]),
                            typeRange: open..<line.index(after: close)))
        }
        return out
    }

    /// The `resolution` value in a type, if it has one.
    ///
    /// Read as its own token because the number is not always last in the bracket:
    /// `continue`, `with_actions` and `default_name '…'` follow it.
    static func resolution(in type: String) -> (value: Int, range: Range<String.Index>)? {
        guard let at = type.range(of: "resolution ") else { return nil }
        let digits = type[at.upperBound...].prefix { $0.isNumber }
        guard !digits.isEmpty, let value = Int(digits) else { return nil }
        return (value, at.upperBound..<type.index(at.upperBound, offsetBy: digits.count))
    }
}
