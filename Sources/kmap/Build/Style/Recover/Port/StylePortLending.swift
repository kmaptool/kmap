import Foundation

extension StylePort.Mapping {
    /// Pictures no rung of theirs was won for, lent from a number that has one.
    func lent(_ won: [MapElementKind: [Int: StylePort.Ported]]) -> [MapElementKind: [Int: StylePort.Ported]] {
        var claimed = won
        // A number split off another for 1 meaning, a grade of it, wears the other's
        // picture: no rung of their ladder is the grade's.
        for (kind, now, was) in StyleCatalog.widenedNumbers {
            guard let was, let parent = claimed[kind]?[was],
                let tags = rules.meaning(kind, now)?.tags, !tags.isEmpty,
                tags == rules.meaning(kind, was)?.tags
            else { continue }
            claimed[kind, default: [:]][now] = StylePort.Ported(
                ours: now,
                theirs: parent.theirs,
                kind: kind,
                meaning: parent.meaning,
                witnesses: parent.witnesses,
                width: parent.width,
                weight: parent.weight
            )
        }
        // Their map marks no via ferrata end: their climber marks it, as in kmap's own styles.
        // Only a picture won for climbing itself, not for a climbing gym's sports centre.
        if claimed[.point]?[StyleCatalog.ferrataEndCode] == nil,
            let climber = claimed[.point]?[StyleCatalog.climbingCode], climber.meaning.contains("climbing")
        {
            claimed[.point, default: [:]][StyleCatalog.ferrataEndCode] = StylePort.Ported(
                ours: StyleCatalog.ferrataEndCode,
                theirs: climber.theirs,
                kind: .point,
                meaning: climber.meaning,
                witnesses: climber.witnesses,
                width: nil,
                weight: climber.weight
            )
        }

        return claimed
    }
}
