import Foundation

/// Steps five and six: the sheets, from what was claimed, silenced, never reached or
/// missing altogether.
extension StyleRecovery {
    /// Rules the foreign style would repaint into a lie are silenced - barracks over
    /// every field. A rule is deleted only when every one of these holds:
    ///
    /// - their TYP defines the code, so their paint would actually land on it; an
    ///   undefined code draws the receiver's own plain default, which harms nothing;
    /// - their map was seen using the code for other meanings - the number is theirs
    ///   and means something else;
    /// - no claim re-aimed the rule, so nothing in their map was found to draw what it
    ///   means. A number carries no meaning of its own: that ours for a ford and theirs
    ///   for an information board are both 0x6514 says nothing about fords, and leaving
    ///   the rule to be painted by that coincidence puts an `i` on every ford. Their
    ///   style has no picture for a ford, so a ford is not drawn - the map ports what
    ///   its author drew, and nothing else;
    /// - the rule carries no routing. A routable rule is function, not look: deleting
    ///   it breaks every route through what it drew, and it cannot be re-aimed either,
    ///   because receivers route only on the plain road types. It keeps its code and
    ///   wears their colours for it, which is the least of the harms on offer.
    static func silencedRuleSheet(verdicts: [String: CodeVerdict],
                                          witnessedSlots: Set<String>,
                                          typDefined: [ElementDumper.Kind: Set<Int>],
                                          claimed: [String: ClaimedRule],
                                          rules: DefaultRuleBook) -> [String] {
        // A map with no TYP to read hands over no vocabulary at all, and silencing every
        // rule against an empty one would leave an empty map.
        guard !typDefined.isEmpty else { return [] }
        var sheet: [String] = []
        for kind in [ElementDumper.Kind.line, .area, .point] {
            let file = DefaultRuleBook.file(for: kind)
            for line in rules.allLines(forKind: file) {
                guard claimed[line.file + ":" + line.text] == nil,
                      let type = Int(line.code, radix: 16) else { continue }
                guard !line.text.contains("road_class=") else { continue }
                guard !Self.generated.contains(
                    Evidence.key(kind, type).uppercased()) else { continue }
                // A point code below 0x100 is a bare type; the TYP folds the subtype in.
                let painted = kind == .point && type < 0x100 ? type << 8 : type
                let verdict = verdicts[codeKey(kind, type)]
                // Their TYP not painting the number is a fact about their style, not
                // about the ground compared: they have no picture for this at all, and
                // the receiver would fall back on its own - a look neither map has.
                // Where they do paint it, only their own witnesses can say whether the
                // picture belongs here; with none either way, their paint stands.
                if typDefined[kind]?.contains(painted) == true, verdict?.agrees != false {
                    continue
                }
                sheet.append("@@ \(line.file)")
                sheet.append(String(format: "# their map draws 0x%02x as %@ — silenced,"
                                    + " so their look stays honest",
                                    type, verdict?.meaning ?? "nothing at all"))
                sheet.append("- \(line.text)")
                if let second = line.continuation { sheet.append("- \(second)") }
            }
        }
        return sheet
    }

    /// Step five - invert: for each rule line, the strongest claim keeps the routing
    /// attributes and closes the rule; every other claim becomes a continue layer
    /// above it.
    static func claimedRuleSheet(
        _ claimed: [String: ClaimedRule],
        ladders: inout [String: [(type: Int, resolutions: [Int: Int])]],
        known: [String: [(type: Int, resolutions: [Int: Int])]] = [:]) -> [String] {
        var sheet: [String] = []
        for (_, entry) in claimed.sorted(by: { $0.key < $1.key }) {
            // One claim per code: a rule reached from two meanings is claimed twice by
            // the same code, which would become a base with a layer of itself on top.
            var byType: [Int: (type: Int, weight: Int, ids: Set<Int64>,
                               tags: [String: Int], resolutions: [Int: Int])] = [:]
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
                byType[type] = (held.type, held.weight, held.ids, held.tags,
                                steadyZooms(held.resolutions))
            }
            guard let line = entry.lines.first else { continue }
            // One meaning, one stroke per zoom: at each resolution the code their map
            // mostly draws this meaning with owns that zoom, and the rest keep quiet
            // there. Without this a rare variant - a via ferrata among paths, a
            // reserve's hatch over the woods inside it - would paint every one of them.
            byType = ownedZooms(byType)
            // A style may keep a second, thinner vocabulary for the zoomed-out levels:
            // a motorway is a stroke six pixels wide up close and one pixel wide on the
            // overview, under a different code. Such a code is told from the detailed
            // one by where each was seen - the zoomed-out stroke stops before the
            // finest zoom the rule is drawn at - and is written as a line of its own
            // over the range it belongs to, rather than stacked everywhere.
            let finest = byType.values.compactMap { $0.resolutions.keys.max() }.max()
            func zoomedOut(_ claim: (type: Int, weight: Int, ids: Set<Int64>,
                                     tags: [String: Int], resolutions: [Int: Int])) -> Bool {
                guard let finest, let highest = claim.resolutions.keys.max() else {
                    return false
                }
                return highest < finest
            }
            // A stroke seen on a handful of elements is the matcher brushing past, not
            // a zoomed-out look: kept, it would be learned as the code's ladder and
            // painted over every rule closing on that code.
            byType = byType.filter { !zoomedOut($0.value) || $0.value.weight >= fewestStroke }
            let overview = byType.values.filter(zoomedOut)
                .sorted { ($0.weight, $0.type) > ($1.weight, $1.type) }
            let overviewTypes = Set(overview.map(\.type))
            let ranked = byType.values.filter { !overviewTypes.contains($0.type) }
                .sorted { ($0.weight, $0.type) > ($1.weight, $1.type) }
            guard let base = ranked.first ?? overview.first else { continue }
            // Several codes each owning their own alternatives split the rule: their
            // style gives gates and bollards each an icon where one rule of ours drew
            // them all. Only when every code's tags are disjoint enough to partition.
            if ranked.count > 1, let split = splitRule(line, ranked: ranked) {
                sheet.append(contentsOf: split)
                continue
            }
            // Layers only where the codes were painted over the same elements; over
            // different ones they are two kinds. A rule split over two lines takes no
            // layers, since a layer would have to repeat the condition.
            // Never the rule's own code: it is already emitted by the line itself, and
            // a layer of it would draw the same stroke twice - two plain road lines
            // under their extended one, thicker and in the plain colour.
            let layers = line.isSplit ? [] : ranked.dropFirst().reversed()
                .filter { paintsTheSame($0.ids, base.ids) && !line.emits($0.type) }
            // The rule's own code holds the line and nothing is painted over it: the
            // line stays as it is - unless a zoomed-out stroke wants a line of its own.
            if line.emits(base.type), layers.isEmpty, overview.isEmpty { continue }
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
            // The paint above this line, as codes and the zooms they own: written out
            // here, and remembered for the rules this evidence never reached.
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
               let known = known[line.file + ":" + String(base.type, radix: 16)] {
                // Only the paint travels: a plain number Garmin routes on belongs to
                // the rule that carries the routing, and a second rule emitting it
                // without those attributes is one way added both routable and not.
                ladder = known.filter {
                    !line.emits($0.type) && $0.type != base.type && !routable($0.type)
                }
            }
            var strokes = ladder.map { stroke in
                stroke.resolutions.isEmpty ? line.layered(to: stroke.type)
                    : banded(line, to: stroke.type, resolutions: stroke.resolutions)
            }
            if ranked.isEmpty {
                // Nothing claimed the rule at its own zoom: it keeps its code, and the
                // strokes follow it.
                remember(&ladders, line.file, line.code, ladder)
                sheet.append(contentsOf: keeping(line, under: strokes))
                continue
            }
            // Garmin routes on the plain types only, so a road rule aimed at an extended
            // type is not routable: the routable line stays, and the borrowed stroke
            // goes over it.
            if !line.isSplit, base.type >= 0x10000, line.text.contains("road_class=") {
                ladder.append((base.type, ladderKnown ? base.resolutions : [:]))
                strokes.append(ladderKnown
                    ? banded(line, to: base.type, resolutions: base.resolutions)
                    : line.layered(to: base.type))
                remember(&ladders, line.file, line.code, ladder)
                sheet.append(contentsOf: keeping(line, under: strokes))
                continue
            }
            remember(&ladders, line.file, String(base.type, radix: 16), ladder)
            sheet.append(contentsOf: keeping(
                closing(line.replacement(to: base.type), of: line,
                        owning: base.resolutions, under: strokes),
                under: strokes))
        }
        return sheet
    }

    /// Notes how a code came out painted, so the rules this pass never saw can be
    /// painted the same way. The fullest reading wins where two rules disagree: the
    /// one that saw the most strokes.
    private static func remember(
        _ ladders: inout [String: [(type: Int, resolutions: [Int: Int])]],
        _ file: String, _ code: String,
        _ strokes: [(type: Int, resolutions: [Int: Int])]) {
        guard !strokes.isEmpty else { return }
        let key = file + ":" + code
        if ladders[key] == nil || ladders[key]!.count < strokes.count {
            ladders[key] = strokes
        }
    }

    /// Step five and a half: the rules this evidence never reached.
    ///
    /// The paint belongs to the code, not to the rule that happened to be witnessed
    /// with it. A roundabout is a trunk road written under `junction=roundabout`, and
    /// the ways carrying that tag were counted as trunk roads - so the trunk rule
    /// learned the ladder and the roundabout rule, drawn on the same blank number,
    /// learned nothing and came out invisible. Any rule closing on a code whose ladder
    /// is known gets that ladder, banded exactly as the witnessed rule's was.
    static func siblingRuleSheet(
        ladders: [String: [(type: Int, resolutions: [Int: Int])]],
        already: Set<String>, rules: DefaultRuleBook) -> [String] {
        var sheet: [String] = []
        for kind in [ElementDumper.Kind.line, .area, .point] {
            let file = DefaultRuleBook.file(for: kind)
            for line in rules.allLines(forKind: file) {
                // A rule written over two lines takes no strokes, here as in the
                // claimed pass: a stroke is one line, and the condition of a rule
                // written apart from its type would be left behind.
                guard !line.isSplit, !already.contains(line.text),
                      let ladder = ladders[line.file + ":" + line.code],
                      !ladder.isEmpty else { continue }
                // A rule already drawn with one of its own strokes needs nothing.
                guard !ladder.contains(where: { line.emits($0.type) }) else { continue }
                let paint = ladder.filter { !routable($0.type) }
                guard !paint.isEmpty else { continue }
                sheet.append("@@ \(line.file)")
                sheet.append("- \(line.text)")
                if let second = line.continuation { sheet.append("- \(second)") }
                let strokes = paint.map {
                    banded(line, to: $0.type, resolutions: $0.resolutions)
                }
                sheet.append(contentsOf: keeping(line, under: strokes))
            }
        }
        return sheet
    }

    /// Step six: rules that did not exist, written above the file's first rule so they
    /// are reached before the general ones. All of a file's additions go in one
    /// substitution, because they share an anchor.
    static func additionSheet(_ additions: [ElementDumper.Kind: [RuleAddition]],
                                      claimed: [String: ClaimedRule],
                                      rules: DefaultRuleBook) -> [String] {
        var sheet: [String] = []
        for (kind, wanted) in additions.sorted(by: { $0.key.rawValue < $1.key.rawValue }) {
            let file = DefaultRuleBook.file(for: kind)
            guard let anchor = rules.firstRuleLine(
                in: file,
                avoiding: Set(claimed.values.flatMap { $0.lines.map(\.text) }))
            else { continue }
            sheet.append("@@ \(file)")
            sheet.append("- \(anchor)")
            // Ties broken by tag then type, so the sheet is byte-identical between runs.
            // Two additions for one tag over the SAME elements are layers, so all but
            // the last continue; over different elements the busier one takes the tag.
            var ordered = wanted.sorted(by: {
                ($0.witnesses, $1.tag, $1.type) > ($1.witnesses, $0.tag, $0.type)
            })
            // Three or more members of one key on one code become one family rule:
            // their style says building=* the same way, and the family catches the
            // long tail of values no floor lets through one by one. Only for a key
            // this kind has no rules of its own under - an addition goes above the
            // whole file, and a wildcard there would shadow every dedicated rule.
            var collapsed: [RuleAddition] = []
            var taken = Set<String>()
            for addition in ordered {
                let familyKey = addition.key + "@" + String(addition.type)
                let members = ordered.filter {
                    $0.key + "@" + String($0.type) == familyKey
                }
                if members.count >= fewestFamily,
                   !rules.hasRules(key: addition.key, kind: kind) {
                    if taken.insert(familyKey).inserted {
                        collapsed.append(RuleAddition(
                            tag: addition.key + "=*", key: addition.key,
                            type: addition.type,
                            witnesses: members.reduce(0) { $0 + $1.witnesses },
                            ids: members.reduce(into: Set<Int64>()) {
                                $0.formUnion($1.ids)
                            },
                            resolutions: members.reduce(into: [Int: Int]()) {
                                $0.merge($1.resolutions, uniquingKeysWith: +)
                            },
                            openOnly: members.filter(\.openOnly).count * 2 > members.count))
                    }
                } else {
                    collapsed.append(addition)
                }
            }
            ordered = collapsed
            for (index, addition) in ordered.enumerated() {
                let resolution = rules.typicalResolution(forKey: addition.key, kind: kind)
                let layered = ordered[(index + 1)...].contains {
                    $0.tag == addition.tag && paintsTheSame($0.ids, addition.ids)
                }
                // A line rule that matches a closed way takes the way out of the
                // polygons file: mkgmap converts it as a line and the fill is never
                // drawn - every building outline, and no building. Where our rules
                // draw this key as an area too, the added line continues, so the map
                // gets both, which is what the borrowed one has.
                let overAnArea = kind == .line && rules.hasRules(key: addition.key,
                                                                 kind: .area)
                sheet.append("# their style draws \(addition.tag), ours had no rule"
                           + " — \(addition.witnesses) of them identified")
                // Pinned to the zooms it was seen at, where those are known: a bare
                // resolution means that zoom and every finer one, which would paint
                // an outline over the zooms another stroke of the same thing owns.
                let band: String
                let zooms = steadyZooms(addition.resolutions)
                if let low = zooms.keys.min(), let high = zooms.keys.max() {
                    band = "\(low)-\(high)"
                } else {
                    band = "\(resolution)"
                }
                // Buildings carrying the tag fall through to the building rule, as
                // their map draws them.
                let condition = addition.tag
                    + (addition.openOnly ? " & " + DefaultRuleBook.openGroundOnly : "")
                sheet.append(String(format: "+ %@ [0x%02x resolution %@%@]",
                                    condition, addition.type, band,
                                    layered || overAnArea ? " continue" : ""))
            }
            sheet.append("+ \(anchor)")
        }
        return sheet
    }
}
