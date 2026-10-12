import Foundation

struct RoadTwinRule {
    /// With actions, from every line of the rule.
    let condition: String
    let type: RoadTwinType
    let bracket: ClosedRange<String.Index>

    /// Drops the rules of actions alone before the type's own rule.
    static func closed(by text: String) -> String {
        let ends = (RoadTwinMarks(text)?.all ?? []).filter { $0.ch == "}" }.map { text.index(after: $0.index) }
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
        for (index, ch) in RoadTwinMarks(condition)?.all ?? [] {
            if ch == "{" { out += condition[from..<index] }
            if ch == "}" { from = condition.index(after: index) }
        }
        out += condition[from...]
        return out.trimmingCharacters(in: .whitespaces)
    }

    /// Whether the condition asks for `tag` itself, not its negation.
    func mentions(_ tag: String) -> Bool {
        let test = Self.test(of: condition)
        var from = test.startIndex
        while let found = test.range(of: tag, range: from..<test.endIndex) {
            let before = found.lowerBound == test.startIndex ? " " : test[test.index(before: found.lowerBound)]
            let after = found.upperBound == test.endIndex ? " " : test[found.upperBound]
            if " (|&".contains(before), " )|&".contains(after), !negated(at: found.lowerBound, in: test) {
                return true
            }
            from = found.upperBound
        }
        return false
    }

    /// Whether `!` opens the brackets around the tag at `index`: `!(highway=x)`.
    private func negated(at index: String.Index, in test: String) -> Bool {
        var at = index
        while at > test.startIndex {
            at = test.index(before: at)
            let ch = test[at]
            if ch == " " || ch == "(" { continue }
            return ch == "!"
        }
        return false
    }

    /// Plain `continue` runs the actions on a copy, so the twin sees the element unchanged.
    func road(in line: String, finest: Int) -> String {
        var options = type.options.filter { !RoadTwinType.continuation.contains($0.key) && $0.key != "level" }
        if let at = options.firstIndex(where: { $0.key == "resolution" }) {
            options[at].value = String(finest)
        } else {
            options.append(("resolution", String(finest)))
        }
        options.append(("continue", nil))
        return line[..<bracket.lowerBound] + RoadTwinType.written(code: type.codeText, options)
            + line[line.index(after: bracket.upperBound)...]
    }

    func twin(code: Int) -> String {
        let options = type.options.filter { $0.key != "road_class" && $0.key != "road_speed" }
        return condition + " " + RoadTwinType.written(code: String(format: "0x%02x", code), options)
    }
}
