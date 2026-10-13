import Foundation

extension StylePort {
    /// 1 rung of their ladder for a meaning: their code, how often and how far in it
    /// was seen, and the ground it covered.
    typealias TheirRung = (code: Int, count: Int, finest: Int, area: Double)

    /// Meaning -> the numbers kmap draws it with, per kind.
    static func ourNumbers(in rules: RuleSetIndex) -> [MapElementKind: [String: Set<Int>]] {
        var out: [MapElementKind: [String: Set<Int>]] = [:]
        for kind in MapElementKind.allCases {
            for meaning in rules.byKind[kind]?.values ?? [:].values {
                // A via ferrata's road lies under its own line: no meaning of the path's number.
                let own = meaning.rules.filter { !$0.condition.contains(StyleCatalog.ownTwin) }
                let tags =
                    own.count == meaning.rules.count
                    ? meaning.tags : RuleSetIndex.distillTags(from: own.map(\.condition))
                for tag in tags {
                    out[kind, default: [:]][tag, default: []].insert(meaning.code)
                }
            }
        }
        return out
    }

    /// Where a rule sits on its ladder: `resolution 22-23` is a rung reaching 23, a
    /// bare `resolution 22` the rule itself, drawn at every zoom from there in.
    static func rung(of tail: String) -> (banded: Bool, finest: Int) {
        guard
            let found = tail.range(
                of: "resolution [0-9]+(-[0-9]+)?",
                options: .regularExpression
            )
        else { return (false, GarminGrid.fullResolution) }
        let numbers = tail[found].split(separator: " ")[1].split(separator: "-")
        guard numbers.count == 2, let high = Int(numbers[1])
        else { return (false, GarminGrid.fullResolution) }
        return (true, high)
    }
}
