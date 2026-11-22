import Foundation

extension StyleRecovery {
    /// What a run left unsettled: how many of the map's codes it saw too little of, never, or with
    /// witnesses that disagree, what it saw of each, and where the rest of the map draws them.
    struct Remainder {
        /// The map's codes in all: those the run met and those drawn only off its ground.
        var codes = 0
        /// Identified on the ground read, and too few times to settle.
        var tooFew = 0
        /// Never identified: met on the ground with nothing matching, or drawn only off
        /// it and no code a build draws already.
        var never = 0
        /// Witnessed, and by sources that disagree.
        var mixed = 0
        /// What the ground read showed of each unsettled code, by `Evidence.slot`.
        var seen: [Int: Sighting] = [:]
        /// The subdivisions off the ground drawing any of those, with their counts of them.
        var drawn: [ImgElements.Tally] = []

        var unsettled: Int { tooFew + never + mixed }

        /// Whether that many codes a region may settle are worth reading it for.
        func isWorth(_ codes: Int) -> Bool { codes >= StyleRecovery.worthARegion }

        /// Among `candidates`, the region whose own ground may settle the most of the
        /// unsettled codes, and how many those are: `Sighting.maySettle`. Nil where none
        /// may settle any. A subdivision counts for the first of `owners` holding its
        /// middle: ground under an extract that is no candidate is nobody's to read again.
        func bestRegion(among candidates: Set<String>, owners: [Region]) -> (region: Region, codes: Int)? {
            // slot -> elements, for every candidate drawing any.
            var held: [Int: [Int: Int]] = [:]
            for tally in drawn {
                // The middle of one across 180 deg may lie past it.
                let lat = (tally.box.minLat + tally.box.maxLat) / 2, past = (tally.box.minLon + tally.box.maxLon) / 2
                let lon = past > 180 ? past - 360 : past < -180 ? past + 360 : past
                guard
                    let owner = owners.firstIndex(where: {
                        $0.bbox.contains(lat: lat, lon: lon) && $0.holds(lat: lat, lon: lon)
                    }), candidates.contains(owners[owner].id)
                else { continue }
                for (slot, count) in tally.codes { held[owner, default: [:]][slot, default: 0] += count }
            }
            let ranked = held.compactMap { owner, counts -> (region: Region, codes: Int, elements: Int)? in
                let may = counts.filter { seen[$0.key]?.maySettle(drawn: $0.value) ?? false }
                return may.isEmpty ? nil : (owners[owner], may.count, may.values.reduce(0, +))
            }
            let best = ranked.max {
                ($0.codes, $0.elements, $1.region.id) < ($1.codes, $1.elements, $0.region.id)
            }
            return best.map { ($0.region, $0.codes) }
        }
    }

    /// Reads the rest of the map for the codes the ground left unsettled.
    static func remainder(
        of img: URL,
        off grounds: [ImgElements.Ground],
        outcomes: [String: Outcome],
        rules: DefaultRuleBook,
        stop: StopFlag
    ) throws -> Remainder {
        var out = Remainder()
        for outcome in outcomes.values {
            switch outcome.status {
            case .singleWitness: out.tooFew += 1
            case .noEvidence: out.never += 1
            case .mixed: out.mixed += 1
            default: continue
            }
            out.seen[Evidence.slot(outcome.kind, outcome.type)] = Remainder.Sighting(
                elements: outcome.elements,
                sources: outcome.witnesses,
                meant: outcome.meant,
                mixed: outcome.status == .mixed
            )
        }
        let census = try ImgElements.census(of: img, off: grounds, stop: stop)
        var offGround: Set<Int> = []
        for tally in census {
            for slot in tally.codes.keys { offGround.insert(slot) }
        }
        for slot in offGround {
            guard let code = Evidence.code(ofSlot: slot) else { continue }
            let key = Evidence.key(code.kind, code.type)
            if outcomes[key] != nil { continue }
            out.codes += 1
            // As on the ground: a code a build draws already has nothing to be learned.
            if !generated.contains(key.uppercased()), !rules.alreadyEmits(code.type, kind: code.kind) {
                out.never += 1
                out.seen[slot] = Remainder.Sighting()
            }
        }
        out.codes += outcomes.count
        out.drawn = census.compactMap { tally in
            let kept = tally.codes.filter { out.seen[$0.key] != nil }
            return kept.isEmpty ? nil : ImgElements.Tally(box: tally.box, codes: kept)
        }
        return out
    }
}
