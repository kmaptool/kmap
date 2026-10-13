import Foundation

extension StylePort {
    /// 1 porting of their pictures onto our numbers: what each side was seen drawing each
    /// meaning with, and the steps that pair them.
    struct Mapping {
        let rules: RuleSetIndex
        let theirTyp: TypSource?
        /// Meaning -> the numbers kmap draws it with, per kind.
        let ourCodes: [MapElementKind: [String: Set<Int>]]
        /// The closest zoom each of our numbers is drawn at.
        let ourFinest: [MapElementKind: [Int: Int]]
        /// Meaning -> every number of theirs that drew it, with how much and at which zooms.
        let theirs: [MapElementKind: [String: [TheirRung]]]
        /// How much each number of theirs drew in all, over every meaning.
        let seen: [String: Int]
        /// Whether their code bearing our number means what ours does.
        let agreement: Agreement

        init(
            codesByTag: [String: [String: Int]],
            rules: RuleSetIndex,
            theirZooms: [String: [Int: Int]],
            theirTyp: TypSource?,
            theirAreas: [String: [String: Double]]
        ) {
            self.rules = rules
            self.theirTyp = theirTyp
            ourCodes = StylePort.ourNumbers(in: rules)
            ourFinest = Self.ourReach(in: rules)
            theirs = Self.theirLadders(
                codesByTag: codesByTag,
                ourCodes: ourCodes,
                theirZooms: theirZooms,
                theirTyp: theirTyp,
                theirAreas: theirAreas
            )
            var seen: [String: Int] = [:]
            for drawn in codesByTag.values {
                for (key, count) in drawn { seen[key, default: 0] += count }
            }
            self.seen = seen
            agreement = Agreement(codesByTag: codesByTag, ourCodes: ourCodes)
        }

        /// Their code for every one of our codes the evidence can speak for, our road
        /// hierarchy kept in the widths.
        func ported() -> [Ported] {
            let ported = lent(claim(offers())).values.flatMap(\.values).sorted {
                ($0.kind.rawValue, $0.ours) < ($1.kind.rawValue, $1.ours)
            }
            return StylePort.ordered(ported, ranks: LineDrawOrder.ranks(in: rules), theirs: theirTyp)
        }
    }
}
