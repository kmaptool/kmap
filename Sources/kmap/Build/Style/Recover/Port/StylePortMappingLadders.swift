import Foundation

extension StylePort.Mapping {
    /// The closest zoom each of our numbers is drawn at, so our own ladder can be read
    /// the same way as theirs.
    static func ourReach(in rules: RuleSetIndex) -> [MapElementKind: [Int: Int]] {
        var ourFinest: [MapElementKind: [Int: Int]] = [:]
        for kind in MapElementKind.allCases {
            for meaning in rules.byKind[kind]?.values ?? [:].values {
                // A rule with no band draws at every zoom and is the closest picture
                // of the meaning; a rung is pinned to a band and belongs further out.
                // Ranked so the bandless comes first, then by how close its band is.
                let reach = meaning.rules.map { StylePort.rung(of: $0.tail) }
                    .min { ($0.banded ? 1 : 0, -$0.finest) < ($1.banded ? 1 : 0, -$1.finest) }
                let held = ourFinest[kind]?[meaning.code] ?? 0
                // The furthest reach wins, whichever meaning is read first: one code can
                // be emitted by several meanings, and a dictionary hands them over in a
                // different order in every process.
                ourFinest[kind, default: [:]][meaning.code] =
                    max(
                        held,
                        (reach?.banded == false)
                            ? StylePort.everyZoom
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
    ) -> [MapElementKind: [String: [StylePort.TheirRung]]] {
        var theirs: [MapElementKind: [String: [StylePort.TheirRung]]] = [:]
        for (tag, drawn) in codesByTag {
            let family = tag.split(separator: "=").first.map { $0 + "=*" }
            for (key, count) in drawn where count >= StylePort.fewestToPort {
                guard let (kind, code) = StylePort.read(key) else { continue }
                // A number their style leaves blank carries no look: it must not take a
                // rung of the ladder and leave the picture below it homeless. A point
                // is no rung, and a blank icon is a look of its own: the name alone.
                if let theirTyp {
                    let section = theirTyp.section(kind, code)
                    if section == nil || (kind != .point && !StylePort.draws(section)) { continue }
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
}
