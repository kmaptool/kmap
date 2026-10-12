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

    /// The closest zoom each of our numbers is drawn at, so our own ladder can be read
    /// the same way as theirs.
    static func ourReach(in rules: RuleSetIndex) -> [MapElementKind: [Int: Int]] {
        var ourFinest: [MapElementKind: [Int: Int]] = [:]
        for kind in MapElementKind.allCases {
            for meaning in rules.byKind[kind]?.values ?? [:].values {
                // A rule with no band draws at every zoom and is the closest picture
                // of the meaning; a rung is pinned to a band and belongs further out.
                // Ranked so the bandless comes first, then by how close its band is.
                let reach = meaning.rules.map { rung(of: $0.tail) }
                    .min { ($0.banded ? 1 : 0, -$0.finest) < ($1.banded ? 1 : 0, -$1.finest) }
                let held = ourFinest[kind]?[meaning.code] ?? 0
                // The furthest reach wins, whichever meaning is read first: one code can
                // be emitted by several meanings, and a dictionary hands them over in a
                // different order in every process.
                ourFinest[kind, default: [:]][meaning.code] =
                    max(
                        held,
                        (reach?.banded == false)
                            ? everyZoom
                            : (reach?.finest ?? GarminGrid.fullResolution)
                    )
            }
        }
        return ourFinest
    }

    /// Their side: meaning -> every number that drew it, with how much and at which
    /// zooms, so a ladder can be told from a single picture. A rule of ours written
    /// for a whole key, `building=*`, is answered by what their map drew for the
    /// values of that key no rule of ours names: a hotel never reaches the
    /// `tourism=*` fallback, so their hotel is no answer for it.
    static func theirLadders(
        codesByTag: [String: [String: Int]],
        ourCodes: [MapElementKind: [String: Set<Int>]],
        theirZooms: [String: [Int: Int]],
        theirTyp: TypSource?,
        theirAreas: [String: [String: Double]]
    ) -> [MapElementKind: [String: [TheirRung]]] {
        var theirs: [MapElementKind: [String: [TheirRung]]] = [:]
        for (tag, drawn) in codesByTag {
            let family = tag.split(separator: "=").first.map { $0 + "=*" }
            for (key, count) in drawn where count >= fewestToPort {
                guard let (kind, code) = read(key) else { continue }
                // A number their style leaves blank carries no look: it must not take a
                // rung of the ladder and leave the picture below it homeless. A point
                // is no rung, and a blank icon is a look of its own: the name alone.
                if let theirTyp {
                    let section = theirTyp.section(kind, code)
                    if section == nil || (kind != .point && !draws(section)) { continue }
                }
                let finest = theirZooms[key]?.keys.max() ?? GarminGrid.fullResolution
                let area = theirAreas[tag]?[key] ?? 0
                theirs[kind, default: [:]][tag, default: []].append((code, count, finest, area))
                if let family, ourCodes[kind]?[tag] == nil {
                    var held = theirs[kind, default: [:]][String(family), default: []]
                    if let at = held.firstIndex(where: { $0.code == code }) {
                        held[at].count += count
                        held[at].area += area
                    } else {
                        held.append((code, count, finest, area))
                    }
                    theirs[kind, default: [:]][String(family)] = held
                }
            }
        }
        return theirs
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
