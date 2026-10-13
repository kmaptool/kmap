import Foundation

extension StyleRecovery.SheetWriter {
    /// Rules that did not exist, written above the file's first rule so they
    /// are reached before the general ones. All of a file's additions go in one
    /// substitution, because they share an anchor.
    func additionSheet() -> [String] {
        var sheet: [String] = []
        for (kind, wanted) in claims.additions.sorted(by: { $0.key.rawValue < $1.key.rawValue }) {
            sheet.append(contentsOf: additionSheet(kind, wanted))
        }
        return sheet
    }

    /// 1 file's additions, above its first rule no claim took.
    private func additionSheet(_ kind: ElementDumper.Kind, _ wanted: [StyleRecovery.RuleAddition]) -> [String] {
        let file = DefaultRuleBook.file(for: kind)
        guard
            let anchor = rules.firstRuleLine(
                in: file,
                avoiding: Set(claimed.values.flatMap { $0.lines.map(\.text) })
            )
        else { return [] }
        var sheet = ["@@ \(file)", "- \(anchor)"]
        // Ties broken by tag then type, so the sheet is byte-identical between runs.
        // 2 additions for 1 tag over the SAME elements are layers, so all but the last
        // continue; over different elements the busier one takes the tag.
        let ordered = Self.families(
            of: wanted.sorted(by: {
                ($0.witnesses, $1.tag, $1.type) > ($1.witnesses, $0.tag, $0.type)
            }),
            kind: kind,
            rules: rules
        )
        // A source counts at the coarsest zoom it was seen at: the addition first seen
        // finest of its tag draws on to the finest zoom.
        var topOfTag: [String: Int] = [:]
        for addition in ordered {
            guard let top = StyleRecovery.steadyZooms(addition.resolutions).keys.max() else { continue }
            topOfTag[addition.tag] = max(topOfTag[addition.tag] ?? top, top)
        }
        for (index, addition) in ordered.enumerated() {
            guard let tag = DefaultRuleBook.condition(addition.tag) else { continue }
            let layered = ordered[(index + 1)...].contains {
                $0.tag == addition.tag && StyleRecovery.paintsTheSame($0.ids, addition.ids)
            }
            sheet.append(
                contentsOf: additionLines(
                    addition,
                    condition: tag,
                    kind: kind,
                    layered: layered,
                    top: topOfTag[addition.tag]
                )
            )
        }
        sheet.append("+ \(anchor)")
        return sheet
    }

    /// Three or more members of one key on one code become one family rule:
    /// their style says building=* the same way, and the family catches the
    /// long tail of values no floor lets through one by one. Only for a key
    /// this kind has no rules of its own under - an addition goes above the
    /// whole file, and a wildcard there would shadow every dedicated rule.
    static func families(
        of ordered: [StyleRecovery.RuleAddition],
        kind: ElementDumper.Kind,
        rules: DefaultRuleBook
    ) -> [StyleRecovery.RuleAddition] {
        var collapsed: [StyleRecovery.RuleAddition] = []
        var taken = Set<String>()
        for addition in ordered {
            let familyKey = addition.key + "@" + String(addition.type)
            let members = ordered.filter {
                $0.key + "@" + String($0.type) == familyKey
            }
            if members.count >= StyleRecovery.fewestFamily,
                !rules.hasRules(key: addition.key, kind: kind)
            {
                if taken.insert(familyKey).inserted {
                    collapsed.append(
                        StyleRecovery.RuleAddition(
                            tag: addition.key + "=*",
                            key: addition.key,
                            type: addition.type,
                            witnesses: members.reduce(0) { $0 + $1.witnesses },
                            ids: members.reduce(into: Set<Int64>()) {
                                $0.formUnion($1.ids)
                            },
                            resolutions: members.reduce(into: [Int: Int]()) {
                                $0.merge($1.resolutions, uniquingKeysWith: +)
                            },
                            openOnly: members.filter(\.openOnly).count * 2 > members.count
                        )
                    )
                }
            } else {
                collapsed.append(addition)
            }
        }
        return collapsed
    }

    /// 1 addition as its note and its rule line, pinned to the zooms it was seen at.
    private func additionLines(
        _ addition: StyleRecovery.RuleAddition,
        condition tag: String,
        kind: ElementDumper.Kind,
        layered: Bool,
        top: Int?
    ) -> [String] {
        var lines: [String] = []
        let resolution = rules.typicalResolution(forKey: addition.key, kind: kind)
        // A line rule that matches a closed way takes the way out of the
        // polygons file: mkgmap converts it as a line and the fill is never
        // drawn - every building outline, and no building. Where our rules
        // draw this key as an area too, the added line continues, so the map
        // gets both, which is what the borrowed one has.
        let overAnArea =
            kind == .line
            && rules.hasRules(
                key: addition.key,
                kind: .area
            )
        lines.append(
            "# their style draws \(addition.tag), ours had no rule"
                + " — \(addition.witnesses) of them identified"
        )
        // Pinned to the zooms it was seen at, where those are known: a bare
        // resolution means that zoom and every finer one, which would paint
        // an outline over the zooms another stroke of the same thing owns.
        let band: String
        let zooms = StyleRecovery.steadyZooms(addition.resolutions)
        if let low = zooms.keys.min(), let high = zooms.keys.max() {
            band = "\(low)-\(high == top ? GarminGrid.fullResolution : high)"
        } else {
            band = "\(resolution)"
        }
        // Buildings carrying the tag fall through to the building rule, as
        // their map draws them.
        let condition =
            tag
            + (addition.openOnly ? " & " + DefaultRuleBook.openGroundOnly : "")
        lines.append(
            String(
                format: "+ %@ [0x%02x resolution %@%@]",
                condition,
                addition.type,
                band,
                layered || overAnArea ? " continue" : ""
            )
        )
        return lines
    }
}
