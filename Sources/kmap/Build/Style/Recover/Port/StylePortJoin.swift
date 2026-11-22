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
                // The buildings another rule claims are told from the sources 1 by 1:
                // few among all their code draws, and no stray.
                let told = tag == StylePort.claimedBuilding
                let real = drawn.filter {
                    Double($0.count) >= StylePort.rungShare * Double(best)
                        && (told || !isStray($0.code, kind, $0.count) || $0.count >= StylePort.fewestIfStray)
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

    /// 2 meanings on 1 number of ours. Where their code IS our number and means what
    /// ours does, the vocabularies agree and that settles it, unless a picture seen
    /// often enough to be believed has more at stake than the namesake weighs: that
    /// picture goes first. Then the fill covering more ground, and elsewhere the
    /// picture seen more often.
    func claim(_ offers: [MapElementKind: [Int: [Int: StylePort.Offer]]]) -> [MapElementKind: [Int: StylePort.Ported]] {
        var claimed: [MapElementKind: [Int: StylePort.Ported]] = [:]
        for (kind, byOurs) in offers {
            for (ours, byTheirs) in byOurs {
                // Their code equals our number for 1 picture at most.
                let namesake = byTheirs[ours].flatMap {
                    agreement.holds(theirs: ours, ours: ours, kind: kind) ? $0 : nil
                }
                // A government office seen 90 times has no other number of ours; the
                // town hall seen 4 times does not keep it for bearing our number.
                func outweighs(_ theirs: Int, _ offer: StylePort.Offer) -> Bool {
                    guard let namesake, theirs != ours, !isStray(theirs, kind, offer.witnesses) else { return false }
                    return atStake(offer, kind, on: ours) > namesake.weight
                }
                let overruled = byTheirs.contains { outweighs($0.key, $0.value) }
                func rank(_ theirs: Int, _ offer: StylePort.Offer) -> Int {
                    if namesake != nil, theirs == ours, !overruled { return 2 }
                    return outweighs(theirs, offer) ? 1 : 0
                }
                let ranked = byTheirs.sorted { a, b in
                    let x = (rank(a.key, a.value), isStray(a.key, kind, a.value.witnesses) ? 0 : 1)
                    let y = (rank(b.key, b.value), isStray(b.key, kind, b.value.witnesses) ? 0 : 1)
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

    /// What a picture loses with a number: the weight of its meanings that no other
    /// number of ours takes whole.
    func atStake(_ offer: StylePort.Offer, _ kind: MapElementKind, on ours: Int) -> Double {
        offer.meanings.filter { (plainHomes[kind]?[$0.tag] ?? []).subtracting([ours]).isEmpty }
            .reduce(0) { $0 + $1.weight }
    }

    /// How much of what their number drew is this meaning: a reserve lies on forest,
    /// so counting alone would paint our reserves as woodland.
    func isStray(_ code: Int, _ kind: MapElementKind, _ count: Int) -> Bool {
        let total = seen[StylePort.key(kind, code)] ?? count
        return Double(count) < StylePort.strayShare * Double(max(total, 1))
    }
}
