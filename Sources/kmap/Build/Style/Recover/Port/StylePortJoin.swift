import Foundation

extension StylePort.Mapping {
    /// The join, rung by rung, both sides from the closest zoom outward: every picture
    /// of theirs offered for each number of ours, summed over the meanings it was seen
    /// for. Rail and disused rail are 1 picture, seen for both.
    func offers() -> [MapElementKind: [Int: [Int: StylePort.Offer]]] {
        var offers: [MapElementKind: [Int: [Int: StylePort.Offer]]] = [:]
        for kind in MapElementKind.allCases {
            for (tag, drawn) in (theirs[kind] ?? [:]).sorted(by: { $0.key < $1.key }) {
                // A rung has to be a real one: a handful of sightings is the matcher
                // brushing past, and it puts grass on the forest below it.
                let best = drawn.map(\.count).max() ?? 0
                // Both tests: enough of this meaning's sightings to be one of its zooms,
                // and enough of what their number drew to be a picture for it. Their
                // plain marker covers 5 fords among 6000 places, and a marker
                // is no ford icon - so the ford stays unpainted, as in the original.
                let real = drawn.filter {
                    Double($0.count) >= StylePort.rungShare * Double(best)
                        && (!isStray($0.code, kind, $0.count) || $0.count >= StylePort.fewestIfStray)
                }
                // The meaning's own ladder, closest zoom first; their code last, so
                // rungs attested alike keep one order between runs.
                let ladder = real.sorted {
                    ($0.finest, $0.count, $0.code) > ($1.finest, $1.count, $1.code)
                }
                guard !ladder.isEmpty else { continue }
                // Ours from the closest zoom outward; between two that draw at every
                // zoom the lower number is the meaning's own, the higher a companion.
                let mine = (ourCodes[kind]?[tag] ?? []).sorted {
                    let a = ourFinest[kind]?[$0] ?? GarminGrid.fullResolution
                    let b = ourFinest[kind]?[$1] ?? GarminGrid.fullResolution
                    return a == b ? $0 < $1 : a > b
                }
                for (at, ours) in mine.enumerated() {
                    // Ours beyond their ladder repeat its coarsest picture rather than
                    // going blank: the road stays visible as it zooms out.
                    let picture = ladder[min(at, ladder.count - 1)]
                    // A line pinned to no band is drawn at every zoom the rule reaches:
                    // the near rung's picture, the far rung's width.
                    let far = ladder.last
                    let spread = kind == .line && ourFinest[kind]?[ours] == StylePort.everyZoom
                    let width =
                        spread
                        ? [
                            theirTyp?.section(kind, picture.code)?.lineWidth,
                            far.flatMap { theirTyp?.section(kind, $0.code)?.lineWidth }
                        ]
                        .compactMap { $0 }.min()
                        : nil
                    let weight = kind == .polygon && picture.area > 0 ? picture.area : Double(picture.count)
                    offers[kind, default: [:]][ours, default: [:]][picture.code, default: StylePort.Offer()]
                        .add(tag, count: picture.count, weight: weight, width: width)
                }
            }
        }
        return offers
    }

    /// 2 meanings on 1 number of ours: where their code IS our number and means what
    /// ours does, the vocabularies agree and that settles it; then the fill covering
    /// more ground, and elsewhere the picture seen more often.
    func claim(_ offers: [MapElementKind: [Int: [Int: StylePort.Offer]]]) -> [MapElementKind: [Int: StylePort.Ported]] {
        func agrees(_ theirs: Int, _ ours: Int, _ kind: MapElementKind) -> Bool {
            agreement.holds(theirs: theirs, ours: ours, kind: kind)
        }
        var claimed: [MapElementKind: [Int: StylePort.Ported]] = [:]
        for (kind, byOurs) in offers {
            for (ours, byTheirs) in byOurs {
                let ranked = byTheirs.sorted { a, b in
                    let x = (
                        agrees(a.key, ours, kind) ? 1 : 0, isStray(a.key, kind, a.value.witnesses) ? 0 : 1
                    )
                    let y = (
                        agrees(b.key, ours, kind) ? 1 : 0, isStray(b.key, kind, b.value.witnesses) ? 0 : 1
                    )
                    return (x.0, x.1, a.value.weight, b.key) > (y.0, y.1, b.value.weight, a.key)
                }
                guard let (code, winner) = ranked.first else { continue }
                let rivals = ranked.dropFirst().flatMap { other in
                    other.value.meanings.map {
                        StylePort.Rival(theirs: other.key, meaning: $0.tag, witnesses: $0.count)
                    }
                }
                claimed[kind, default: [:]][ours] = StylePort.Ported(
                    ours: ours,
                    theirs: code,
                    kind: kind,
                    meaning: winner.meaning,
                    witnesses: winner.witnesses,
                    width: winner.width,
                    weight: winner.weight,
                    rivals: rivals
                )
            }
        }
        return claimed
    }

    /// How much of what their number drew is this meaning: a reserve lies on forest,
    /// so counting alone would paint our reserves as woodland.
    func isStray(_ code: Int, _ kind: MapElementKind, _ count: Int) -> Bool {
        let total = seen[StylePort.key(kind, code)] ?? count
        return Double(count) < StylePort.strayShare * Double(max(total, 1))
    }
}
