import Foundation

extension StyleRecovery {
    /// Writes the reassignment sheet from what resolving the codes settled.
    struct SheetWriter {
        /// A code painted over a rule, and the zooms it owns there.
        typealias Stroke = (type: Int, resolutions: [Int: Int])

        let claims: Claims
        /// Rule chains their map was seen drawing, which are never silenced.
        let witnessedSlots: Set<String>
        /// The codes their TYP paints, per kind.
        let typDefined: [ElementDumper.Kind: Set<Int>]
        let rules: DefaultRuleBook
        /// The rules spoken for: the claimed ones, and the ones narrowed to open ground.
        private(set) var claimed: [String: ClaimedRule]
        /// How each code came out painted, so the rules this evidence never reached can be
        /// painted the same way.
        private(set) var ladders: [String: [Stroke]] = [:]

        init(
            claims: Claims,
            witnessedSlots: Set<String>,
            typDefined: [ElementDumper.Kind: Set<Int>],
            rules: DefaultRuleBook
        ) {
            self.claims = claims
            self.witnessedSlots = witnessedSlots
            self.typDefined = typDefined
            self.rules = rules
            claimed = claims.rules
        }

        /// The claimed rules, the rules narrowed to open ground, the additions, the rules
        /// silenced and the rules their siblings repaint.
        mutating func write() -> [String] {
            // Twice: the first pass only learns how each code came out painted, so the
            // second can paint a rule the evidence left bare the way its code is painted
            // elsewhere - whichever order the rules happen to be in.
            _ = claimedRuleSheet(known: [:])
            let learned = ladders
            var sheet = claimedRuleSheet(known: learned)
            sheet.append(contentsOf: narrowedSheet())
            sheet.append(contentsOf: additionSheet())
            sheet.append(contentsOf: silencedRuleSheet())
            // Every anchor already spoken for: a rule is rewritten once, or the second
            // substitution finds nothing to stand on.
            let already = Set(sheet.filter { $0.hasPrefix("- ") }.map { String($0.dropFirst(2)) })
            sheet.append(contentsOf: siblingRuleSheet(already: already))
            return sheet
        }

        /// Invert: for each rule line, the strongest claim keeps the routing attributes and
        /// closes the rule; every other claim becomes a continue layer above it.
        private mutating func claimedRuleSheet(known: [String: [Stroke]]) -> [String] {
            var sheet: [String] = []
            for (_, entry) in claimed.sorted(by: { $0.key < $1.key }) {
                sheet.append(contentsOf: ruleSheet(entry, known: known))
            }
            return sheet
        }

        /// The sheet lines for 1 claimed rule: the strongest claim keeps the routing and closes
        /// the rule, every other claim becomes a layer above it.
        private mutating func ruleSheet(_ entry: ClaimedRule, known: [String: [Stroke]]) -> [String] {
            var sheet: [String] = []
            let byType = Self.claimsByCode(entry)
            guard let line = entry.lines.first else { return [] }
            let (ranked, overview) = Self.rankedClaims(byType)
            guard let base = ranked.first ?? overview.first else { return [] }
            // Several codes each owning their own alternatives split the rule: their
            // style gives gates and bollards each an icon where one rule of ours drew
            // them all. Only when every code's tags are disjoint enough to partition.
            if ranked.count > 1, let split = Self.splitRule(line, ranked: ranked) {
                sheet.append(contentsOf: split)
                return sheet
            }
            // Layers only where the codes were painted over the same elements; over
            // different ones they are two kinds. A rule split over two lines takes no
            // layers, since a layer would have to repeat the condition.
            // Never the rule's own code: it is already emitted by the line itself, and
            // a layer of it would draw the same stroke twice - two plain road lines
            // under their extended one, thicker and in the plain colour.
            let layers =
                line.isSplit
                ? []
                : ranked.dropFirst().reversed()
                    .filter { StyleRecovery.paintsTheSame($0.ids, base.ids) && !line.emits($0.type) }
            // The rule's own code holds the line and nothing is painted over it: the
            // line stays as it is - unless a zoomed-out stroke wants a line of its own.
            if line.emits(base.type), layers.isEmpty, overview.isEmpty { return [] }
            sheet.append("@@ \(line.file)")
            sheet.append("- \(line.text)")
            // A rule written over two lines is REPLACED over two lines: both go into the
            // anchor, or mkgmap refuses the style with "Stack size is 0".
            if let second = line.continuation { sheet.append("- \(second)") }
            // Order is what a receiver draws by: the elements of one way are painted in
            // the order the rules add them, so what comes last lies on top. The
            // borrowed map does the same - a bridge's casing first, the road over it -
            // so the rule that carries the routing goes first and the strokes follow,
            // each over exactly the band it was seen at. A bare `resolution N` means N
            // and everything finer, which would pile a stroke onto the zooms its
            // neighbours own; a band hands those zooms over. With no other stroke to
            // hand them to, the lone one keeps the rule's own resolution.
            let ladderKnown = !overview.isEmpty
            var ladder = Self.ladder(over: line, base: base, overview: overview, layers: layers, known: known)
            var strokes = ladder.map { stroke in
                stroke.resolutions.isEmpty
                    ? line.layered(to: stroke.type)
                    : Self.banded(line, to: stroke.type, resolutions: stroke.resolutions)
            }
            if ranked.isEmpty {
                // Nothing claimed the rule at its own zoom: it keeps its code, and the
                // strokes follow it.
                remember(line.file, line.code, ladder)
                sheet.append(contentsOf: Self.keeping(line, under: strokes))
                return sheet
            }
            // Garmin routes on the plain types only, so a road rule aimed at an extended
            // type is not routable: the routable line stays, and the borrowed stroke
            // goes over it.
            if !line.isSplit, base.type >= 0x10000, line.text.contains("road_class=") {
                ladder.append((base.type, ladderKnown ? base.resolutions : [:]))
                // The base is first seen finest of the ladder: from there it draws on.
                let finest = (Self.bandTops(strokes) ?? [Int.max]).allSatisfy { $0 <= base.resolutions.keys.max() ?? 0 }
                strokes.append(
                    ladderKnown
                        ? Self.banded(line, to: base.type, resolutions: base.resolutions, toFinest: finest)
                        : line.layered(to: base.type)
                )
                remember(line.file, line.code, ladder)
                sheet.append(contentsOf: Self.keeping(line, under: strokes))
                return sheet
            }
            remember(line.file, String(base.type, radix: 16), ladder)
            sheet.append(
                contentsOf: Self.keeping(
                    Self.closing(
                        line.replacement(to: base.type),
                        of: line,
                        owning: base.resolutions,
                        under: strokes
                    ),
                    under: strokes
                )
            )
            return sheet
        }

        /// Notes how a code came out painted, so the rules this pass never saw can be
        /// painted the same way. The fullest reading wins where two rules disagree: the
        /// one that saw the most strokes.
        private mutating func remember(_ file: String, _ code: String, _ strokes: [Stroke]) {
            guard !strokes.isEmpty else { return }
            let key = file + ":" + code
            if ladders[key] == nil || ladders[key]!.count < strokes.count {
                ladders[key] = strokes
            }
        }

        /// Rules narrowed to open ground, which no claim rewrote already: the buildings fall
        /// through to the building rule.
        private mutating func narrowedSheet() -> [String] {
            var sheet: [String] = []
            for (slot, line) in claims.narrowed.sorted(by: { $0.key < $1.key })
            where claimed[slot] == nil {
                guard let open = line.narrowedToOpenGround() else { continue }
                sheet.append("@@ \(line.file)")
                sheet.append("- \(line.text)")
                if let second = line.continuation { sheet.append("- \(second)") }
                sheet.append(contentsOf: open.map { "+ " + $0 })
                claimed[slot] = ClaimedRule(lines: [line])
            }
            return sheet
        }
    }
}
