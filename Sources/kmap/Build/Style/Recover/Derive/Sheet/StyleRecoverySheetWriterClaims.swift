import Foundation

extension StyleRecovery.SheetWriter {
    /// A rule line's claims, 1 per code: a rule reached from 2 meanings is claimed twice by
    /// the same code, which would become a base with a layer of itself on top.
    static func claimsByCode(_ entry: StyleRecovery.ClaimedRule) -> [Int: StyleRecovery.CodeClaim] {
        var byType: [Int: StyleRecovery.CodeClaim] = [:]
        for claim in entry.codes {
            if var held = byType[claim.type] {
                held.weight += claim.weight
                held.ids.formUnion(claim.ids)
                held.tags.merge(claim.tags, uniquingKeysWith: +)
                held.resolutions.merge(claim.resolutions, uniquingKeysWith: +)
                byType[claim.type] = held
            } else {
                byType[claim.type] = claim
            }
        }
        for (type, held) in byType {
            byType[type] = (
                held.type, held.weight, held.ids, held.tags,
                StyleRecovery.steadyZooms(held.resolutions)
            )
        }
        return byType
    }

    /// A rule's claims by zoom: the codes drawing it up close, strongest first, and the
    /// strokes of a second, thinner vocabulary for the zoomed-out levels.
    static func rankedClaims(
        _ claims: [Int: StyleRecovery.CodeClaim]
    ) -> (ranked: [StyleRecovery.CodeClaim], overview: [StyleRecovery.CodeClaim]) {
        var byType = claims
        // One meaning, one stroke per zoom: at each resolution the code their map
        // mostly draws this meaning with owns that zoom, and the rest keep quiet
        // there. Without this a rare variant - a via ferrata among paths, a
        // reserve's hatch over the woods inside it - would paint every one of them.
        byType = Self.ownedZooms(byType)
        // A style may keep a second, thinner vocabulary for the zoomed-out levels:
        // a motorway is a stroke six pixels wide up close and one pixel wide on the
        // overview, under a different code. Such a code is told from the detailed
        // one by where each was seen - the zoomed-out stroke stops before the
        // finest zoom the rule is drawn at - and is written as a line of its own
        // over the range it belongs to, rather than stacked everywhere.
        let finest = byType.values.compactMap { $0.resolutions.keys.max() }.max()
        func zoomedOut(_ claim: StyleRecovery.CodeClaim) -> Bool {
            guard let finest, let highest = claim.resolutions.keys.max() else {
                return false
            }
            return highest < finest
        }
        // A stroke seen on a handful of elements is the matcher brushing past, not
        // a zoomed-out look: kept, it would be learned as the code's ladder and
        // painted over every rule closing on that code.
        byType = byType.filter { !zoomedOut($0.value) || $0.value.weight >= StyleRecovery.fewestStroke }
        let overview = byType.values.filter(zoomedOut)
            .sorted { ($0.weight, $0.type) > ($1.weight, $1.type) }
        let overviewTypes = Set(overview.map(\.type))
        let ranked = byType.values.filter { !overviewTypes.contains($0.type) }
            .sorted { ($0.weight, $0.type) > ($1.weight, $1.type) }
        return (ranked, overview)
    }

    /// The paint above a rule line, as codes and the zooms they own: written out here, and
    /// remembered for the rules this evidence never reached.
    static func ladder(
        over line: DefaultRuleBook.Line,
        base: StyleRecovery.CodeClaim,
        overview: [StyleRecovery.CodeClaim],
        layers: [StyleRecovery.CodeClaim],
        known: [String: [(type: Int, resolutions: [Int: Int])]]
    ) -> [(type: Int, resolutions: [Int: Int])] {
        let ladderKnown = !overview.isEmpty
        var ladder: [(type: Int, resolutions: [Int: Int])] = []
        // Never the rule's own code: a claim on the number the line already emits
        // would write that number a second time, without the routing attributes -
        // which mkgmap reads as one way added both routable and not, and says so.
        for stroke in overview where !line.isSplit && !line.emits(stroke.type) {
            ladder.append((stroke.type, stroke.resolutions))
        }
        for layer in layers {
            ladder.append((layer.type, ladderKnown ? layer.resolutions : [:]))
        }
        // A rule the evidence left bare is painted like every other rule closing on
        // its code: a roundabout is a trunk road written under another tag, and the
        // ways carrying it were counted as trunk roads.
        if ladder.isEmpty, !line.isSplit,
            let known = known[line.file + ":" + String(base.type, radix: 16)]
        {
            // Only the paint travels: a plain number Garmin routes on belongs to
            // the rule that carries the routing, and a second rule emitting it
            // without those attributes is one way added both routable and not.
            ladder = known.filter {
                !line.emits($0.type) && $0.type != base.type && !StyleRecovery.routable($0.type)
            }
        }
        return ladder
    }
}
