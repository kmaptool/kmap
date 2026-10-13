import Foundation

extension StyleRecovery.Resolver {
    /// Which of a code's meanings the sheet should honour: every one above the noise
    /// floor that has a rule, earns its own, or belongs to a family that earned one -
    /// and where those cover too little, one whole family if a single key accounts for
    /// what `StyleRecovery.purity` asks. nil when the code stays unresolved.
    func chooseMeanings(
        of entry: StyleRecovery.CodeReading,
        ranked: [(key: String, value: StyleRecovery.MeaningBucket)],
        outcome: inout StyleRecovery.Outcome
    ) -> [(key: String, value: StyleRecovery.MeaningBucket)]? {
        // A foreign code may stand for more than one rule, and may give a whole
        // family one mark. Every meaning above the noise floor is a claim - and so is
        // one below it that this code nonetheless leads: 100 gardens are not
        // noise on a code that also draws every meadow, when nothing else draws
        // gardens at all.
        let floor = entry.floor
        func leads(_ bucket: StyleRecovery.MeaningBucket) -> Bool {
            bucket.tags.contains { tag, count in
                count >= StyleRecovery.fewestOutright
                    && count >= leaders.tag["\(entry.code.kind.rawValue)@\(tag)"] ?? count
                    // Leading a tag nobody else claims is worth nothing where the tag
                    // is everywhere and the claim is a handful: a style that draws a
                    // thing draws most of them.
                    && Double(count) >= StyleRecovery.drawnShare * Double(ground[tag] ?? count)
            }
        }
        var above = ranked.filter {
            $0.value.count >= floor
                || (!$0.value.lines.isEmpty && leads($0.value))
                || (entry.code.kind == .point && leads($0.value))
        }
        // A family the default rules never had: once one member of a key has earned
        // a rule of its own, the rest of that key come with it. A key already drawn
        // is no such family, only a side-tag riding along.
        let families = Set(
            above.filter {
                $0.value.lines.isEmpty
                    && Double($0.value.count) >= StyleRecovery.ownRule * Double(entry.meant)
            }.map { StyleRecovery.key(of: $0.value.name) }
        )
        // A family's long tail rides in with the family: their map that draws every
        // power tower also draws its poles, however few of them the floor would pass.
        for pair in ranked
        where pair.value.count < floor && pair.value.count >= StyleRecovery.fewestOutright
            && families.contains(StyleRecovery.key(of: pair.value.name)) && leads(pair.value)
        {
            above.append(pair)
        }
        let wanted = above.filter { pair in
            !pair.value.lines.isEmpty
                || Double(pair.value.count) >= StyleRecovery.ownRule * Double(entry.meant)
                || families.contains(StyleRecovery.key(of: pair.value.name))
                || (entry.code.kind == .point && leads(pair.value))
        }
        let covered = wanted.reduce(0) { $0 + $1.value.count }
        // Purity is asked over the plausible witnesses only: a meaning with no rule of
        // this kind and no hope of earning one is identification noise - a fence
        // matched onto the yard it encloses - not a rival reading of the code.
        let implausible = above.filter {
            $0.value.lines.isEmpty
                && !families.contains(StyleRecovery.key(of: $0.value.name))
                && Double($0.value.count) < StyleRecovery.ownRule * Double(entry.meant)
        }.reduce(0) { $0 + $1.value.count }
        let plausible = max(1, entry.meant - implausible)
        if !wanted.isEmpty, Double(covered) / Double(plausible) >= StyleRecovery.purity {
            return wanted
        }

        // One mark for a whole family: no single meaning holds the code, but one
        // key accounts for what `StyleRecovery.purity` asks of a meaning. The sheet takes the
        // members above the floor; the tail keeps the default rules.
        let keyed = Dictionary(grouping: ranked) { StyleRecovery.key(of: $0.value.name) }
        let family = keyed.filter { !$0.key.isEmpty }
            .max { a, b in
                (a.value.reduce(0) { $0 + $1.value.count }, b.key)
                    < (b.value.reduce(0) { $0 + $1.value.count }, a.key)
            }
        let held = family?.value.reduce(0) { $0 + $1.value.count } ?? 0
        guard entry.meant >= StyleRecovery.scarce, let family,
            Double(held) / Double(plausible) >= StyleRecovery.purity
        else {
            if let led = mopUp(
                of: entry,
                ranked: ranked,
                outcome: &outcome
            ) {
                return led
            }
            if !above.isEmpty, above.allSatisfy({ $0.value.lines.isEmpty }) {
                // Everything it draws has no rule at all, and not enough of any
                // one meaning to write one.
                outcome.status = .noRule
            }
            return nil
        }
        let chosen = family.value.filter { $0.value.count >= floor }
        if !chosen.isEmpty {
            outcome.meaning += " — one mark for \(family.key)"
            return chosen
        }
        return nil
    }

    /// The mop-up verdict, tried when no single meaning and no family holds the code:
    /// a style may draw one plain dot for what ours gives a dozen icons. Every meaning
    /// the code leads outright - nothing else of this kind draws the tag - is honoured,
    /// with a rule to re-aim or a rule to add.
    func mopUp(
        of entry: StyleRecovery.CodeReading,
        ranked: [(key: String, value: StyleRecovery.MeaningBucket)],
        outcome: inout StyleRecovery.Outcome
    ) -> [(key: String, value: StyleRecovery.MeaningBucket)]? {
        let led = ranked.filter { pair in
            pair.value.tags.contains { tag, count in
                count >= StyleRecovery.fewestOutright
                    && count >= leaders.tag["\(entry.code.kind.rawValue)@\(tag)"] ?? count
            }
        }
        guard led.count >= StyleRecovery.fewestLed else { return nil }
        outcome.meaning += " — a mop-up mark, honoured where it leads"
        return led
    }

    /// Whether a chosen meaning is the code's own: a meaning belongs to the code that draws
    /// most of it, and the lesser code is left alone.
    func isOwn(
        _ pair: (key: String, value: StyleRecovery.MeaningBucket),
        of entry: StyleRecovery.CodeReading
    ) -> Bool {
        if Double(pair.value.count)
            >= StyleRecovery.stray * Double(leaders.meaning[pair.key] ?? pair.value.count)
        {
            return true
        }
        // Measured within its class: the yards of a thing are not a stray of
        // the buildings of it.
        let classed = StyleRecovery.classKey(pair.key, pair.value)
        if Double(pair.value.count)
            >= StyleRecovery.stray * Double(leaders.classed[classed] ?? pair.value.count)
        {
            return true
        }
        // A zoomed-out stroke draws the same meaning where the busy code does not,
        // so it is measured against nobody: far fewer elements survive a coarse
        // zoom, and that is the point of the stroke, not a sign of a stray. It has
        // to be what the code is mostly for, though - a hatch drawn over a reserve
        // brushes the woods inside it, and that overlap is not a stroke for woods.
        if let finest = entry.code.resolutions.keys.max(),
            let drawn = leaders.finest[pair.key], finest < drawn,
            pair.value.count >= StyleRecovery.fewestStroke,
            Double(pair.value.count) >= StyleRecovery.stray * Double(entry.meant)
        {
            return true
        }
        // A stray on the chain may still own one of its tags outright: the code
        // drawing most of the map's bollards is no stray under the gates.
        return pair.value.tags.contains { tag, count in
            count >= StyleRecovery.fewestWitnesses
                && count >= leaders.tag["\(entry.code.kind.rawValue)@\(tag)"] ?? count
        }
    }
}
