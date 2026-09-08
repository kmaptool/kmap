import Foundation

/// From evidence to a sheet: what each foreign code was seen drawing, which claims
/// survive the thresholds, and the substitutions the sheet is written from.
extension StyleRecovery {
    /// The share of what a code's witnesses meant that its claims have to account for.
    /// Below it the code stands for too many different things to speak for any of them.
    static let purity = 0.8

    /// Noise floor: a meaning holding less than this share of a code's witnesses is not
    /// what the code is for. Low, because a foreign style may draw a whole family with
    /// one mark; `stray` below is what keeps a low floor honest.
    static let noise = 0.02

    /// Writing a rule the style never had claims the code is FOR that meaning, a larger
    /// claim than re-aiming an existing rule, so it takes this share of the code's
    /// witnesses. A side-tag riding along on another meaning would otherwise earn one.
    static let ownRule = 0.25

    /// A claim that stands only because nothing else claims the tag must still cover
    /// this share of the things carrying it on the ground.
    ///
    /// Their icon for a lift gate was seen eleven times over a pedestrian crossing —
    /// a gate sits near one — and nothing else drew crossings, so eleven witnesses
    /// were about to put a gate on every crossing in the map: three and a half
    /// thousand of them. A style that draws a thing draws most of them; a handful out
    /// of thousands is the matcher brushing past, not a meaning.
    static let drawnShare = 0.05

    /// A meaning belongs to the code that mostly draws it. A claim holding less than
    /// this share of the strongest claim on the same meaning is a stray and is dropped.
    static let stray = 0.2

    /// How much of the smaller code's elements have to be found under the larger one for
    /// the two to be layers of one drawing rather than two kinds drawn apart.
    static let sameElements = 0.5

    /// Fewer identifications than this are reported as too little seen rather than as a
    /// disagreement.
    static let scarce = 6

    /// However low the noise floor comes out, at least this many witnesses must agree
    /// before a meaning counts as a claim.
    static let fewestWitnesses = 3

    /// One meaning, as the default rules see it, and the witnesses a foreign code
    /// gave it. Keyed per rule rather than per tag: two tags that open one rule are
    /// one meaning. A meaning with no rule keeps its tag as its own key.
    private struct MeaningBucket {
        var lines: [DefaultRuleBook.Line]
        var tags: [String: Int] = [:]
        /// How many of this meaning's witnesses were seen at each zoom, so a ladder is
        /// read per zoom: one meaning, one stroke at a time.
        var resolutions: [Int: Int] = [:]
        /// The witnesses themselves: shared elements make two codes two layers of
        /// one drawing rather than two kinds.
        var ids: Set<Int64> = []
        var count: Int { ids.count }
        /// The commonest tag in it: what the report shows, and what a rule written
        /// for it is written from.
        var name: String {
            tags.max { ($0.value, $1.key) < ($1.value, $0.key) }?.key ?? ""
        }
    }

    /// What one foreign code's witnesses meant, before anything has been decided.
    private struct CodeReading {
        let key: String
        let code: Evidence.ForCode
        let buckets: [String: MeaningBucket]
        /// Witnesses that meant anything at all.
        let meant: Int
        /// Whether the code is absent from the default rules. A default code writes
        /// nothing to the sheet, but its witnesses still count towards which code
        /// owns a meaning.
        let foreign: Bool

        /// The noise floor for this code: below it a meaning is a side-tag, not a claim.
        var floor: Int { max(fewestWitnesses, Int(Double(meant) * noise)) }
    }

    /// One rule line, and every foreign code laying claim to it. A style painting a
    /// road as casing, fill and a low-zoom stroke has three codes for one rule, and
    /// all three belong in the sheet as layers.
    private struct ClaimedRule {
        let lines: [DefaultRuleBook.Line]
        var codes: [(type: Int, weight: Int, ids: Set<Int64>, tags: [String: Int],
                     resolutions: [Int: Int])] = []
    }

    /// A rule the style does not have, to be written for a code that needs one.
    private struct RuleAddition {
        let tag: String
        let key: String
        let type: Int
        let witnesses: Int
        /// The elements it was seen on: for one tag, the same elements are two
        /// layers and different ones are two kinds.
        let ids: Set<Int64>
        /// The zooms the code was seen drawn at, so a rule written for it draws
        /// where its author drew it rather than at every zoom below.
        var resolutions: [Int: Int] = [:]
    }

    /// Internal rather than private, so the tests can feed it hand-built evidence.
    ///
    /// Six steps: read what every code's witnesses meant, find the strongest claim on
    /// each meaning, let the default codes claim their own lines, resolve each foreign
    /// code into claims and additions, then write the claimed rules and the additions
    /// out as the sheet.
    /// - Parameter ground: how many things carrying each meaning the compared ground
    ///   holds, so a claim can be weighed against what there was to draw.
    static func derive(_ evidence: Evidence, into report: inout Report,
                       rules: DefaultRuleBook = .load(),
                       typDefined: [ElementDumper.Kind: Set<Int>] = [:],
                       ground: [String: Int] = [:]) {
        let read = readCodes(evidence, into: &report, rules: rules)

        // A meaning belongs to the code that mostly draws it, so every claim on it is
        // measured against the strongest claim made on it.
        var leader: [String: Int] = [:]
        // And per tag: a code drawing few of a chain's many tags is a stray on the
        // chain, yet the rightful owner of its own tag — bollards under the gates.
        var tagLeader: [String: Int] = [:]
        // The finest zoom each meaning is drawn at, over every code: a stroke that
        // stops short of it is the same meaning at another zoom, not a stray.
        var bucketFinest: [String: Int] = [:]
        for entry in read {
            for (bucket, meaning) in entry.buckets {
                leader[bucket] = max(leader[bucket] ?? 0, meaning.count)
                if let finest = entry.code.resolutions.keys.max() {
                    bucketFinest[bucket] = max(bucketFinest[bucket] ?? 0, finest)
                }
                for (tag, count) in meaning.tags {
                    tagLeader["\(entry.code.kind.rawValue)@\(tag)"]
                        = max(tagLeader["\(entry.code.kind.rawValue)@\(tag)"] ?? 0, count)
                }
            }
        }

        var claimed: [String: ClaimedRule] = [:]
        var additions: [ElementDumper.Kind: [RuleAddition]] = [:]

        // A default code claims the lines it already emits: a foreign code painted over
        // the same elements then becomes a layer above it, not a replacement or a stray.
        for entry in read where !entry.foreign {
            for (_, meaning) in entry.buckets where meaning.count >= entry.floor {
                for line in meaning.lines where line.emits(entry.code.type) {
                    let slot = line.file + ":" + line.text
                    var claim = claimed[slot] ?? ClaimedRule(lines: [line])
                    claim.codes.append((entry.code.type, meaning.count, meaning.ids,
                                        meaning.tags, meaning.resolutions))
                    claimed[slot] = claim
                }
            }
        }

        // Every witnessed code resolves — a foreign number and a colliding one alike. A
        // number the default set also uses is no promise the foreign style means the
        // same thing by it: this map drew barracks as 0x1c, which is kmap's farmland.
        // The same evidence, reachable by code: a claim asks whether a line's own
        // code was itself seen drawing the meaning before re-aiming the line away.
        var readByCode: [String: CodeReading] = [:]
        for entry in read { readByCode[codeKey(entry.code.kind, entry.code.type)] = entry }

        var verdicts: [String: CodeVerdict] = [:]
        for entry in read {
            var outcome = resolve(entry, leader: leader, tagLeader: tagLeader,
                                  bucketFinest: bucketFinest, ground: ground,
                                  claimed: &claimed,
                                  additions: &additions, readByCode: readByCode,
                                  verdicts: &verdicts)
            if !entry.foreign {
                outcome.meaning = outcome.meaning.isEmpty
                    ? "a default code" : outcome.meaning + " — a default code too"
            }
            report.outcomes[entry.key] = outcome
        }

        // Rule chains the foreign map was seen drawing, per kind: a rule of a drawn
        // chain is never silenced — the claims have already said what happens to it.
        var witnessedSlots = Set<String>()
        for entry in read {
            for (_, bucket) in entry.buckets where bucket.count >= fewestWitnesses {
                for line in bucket.lines {
                    witnessedSlots.insert(
                        "\(entry.code.kind.rawValue):\(line.file):\(line.text)")
                }
            }
        }

        // Twice: the first pass only learns how each code came out painted, so the
        // second can paint a rule the evidence left bare the way its code is painted
        // elsewhere — whichever order the rules happen to be in.
        var ladders: [String: [(type: Int, resolutions: [Int: Int])]] = [:]
        _ = claimedRuleSheet(claimed, ladders: &ladders)
        let learned = ladders
        var sheet = claimedRuleSheet(claimed, ladders: &ladders, known: learned)
        sheet.append(contentsOf: additionSheet(additions, claimed: claimed, rules: rules))
        sheet.append(contentsOf: silencedRuleSheet(verdicts: verdicts,
                                                   witnessedSlots: witnessedSlots,
                                                   typDefined: typDefined,
                                                   claimed: claimed, rules: rules))
        // Every anchor already spoken for: a rule is rewritten once, or the second
        // substitution finds nothing to stand on.
        let already = Set(sheet.filter { $0.hasPrefix("- ") }.map { String($0.dropFirst(2)) })
        sheet.append(contentsOf: siblingRuleSheet(ladders: ladders, already: already,
                                                  rules: rules))
        report.sheet = sheet.joined(separator: "\n")
    }

    /// What resolving one code decided, kept for the silencing pass: whether any chosen
    /// meaning already emits the code — the two vocabularies agreeing on the number —
    /// and the words for the comment when they do not.
    private struct CodeVerdict {
        let agrees: Bool
        let meaning: String
    }

    private static func codeKey(_ kind: ElementDumper.Kind, _ type: Int) -> String {
        "\(kind.rawValue):\(String(type, radix: 16))"
    }

    /// Rules the foreign style would repaint into a lie are silenced — barracks over
    /// every field. A rule is deleted only when every one of these holds:
    ///
    /// - their TYP defines the code, so their paint would actually land on it; an
    ///   undefined code draws the receiver's own plain default, which harms nothing;
    /// - their map was seen using the code for other meanings — the number is theirs
    ///   and means something else;
    /// - no claim re-aimed the rule, so nothing in their map was found to draw what it
    ///   means. A number carries no meaning of its own: that ours for a ford and theirs
    ///   for an information board are both 0x6514 says nothing about fords, and leaving
    ///   the rule to be painted by that coincidence puts an `i` on every ford. Their
    ///   style has no picture for a ford, so a ford is not drawn — the map ports what
    ///   its author drew, and nothing else;
    /// - the rule carries no routing. A routable rule is function, not look: deleting
    ///   it breaks every route through what it drew, and it cannot be re-aimed either,
    ///   because receivers route only on the plain road types. It keeps its code and
    ///   wears their colours for it, which is the least of the harms on offer.
    private static func silencedRuleSheet(verdicts: [String: CodeVerdict],
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
                // the receiver would fall back on its own — a look neither map has.
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

    /// Step one: what every code's witnesses meant, bucketed per rule. Codes that are
    /// settled without evidence — generated by the build, or already a default code —
    /// go straight into the report.
    private static func readCodes(_ evidence: Evidence, into report: inout Report,
                                  rules: DefaultRuleBook) -> [CodeReading] {
        var read: [CodeReading] = []
        for (key, code) in evidence.codes {
            var outcome = Outcome(kind: code.kind, type: code.type,
                                  witnesses: code.sources.count, elements: code.elements,
                                  unmatched: code.unmatched, ambiguous: code.ambiguous,
                                  meaning: "", status: .noEvidence,
                                  resolutions: code.resolutions)

            // A code the default set already uses is not foreign: nothing to write.
            if Self.generated.contains(Evidence.key(code.kind, code.type).uppercased()) {
                outcome.status = .resolved
                outcome.meaning = "generated by the build, no ground source"
                report.outcomes[key] = outcome
                continue
            }
            let foreign = !rules.alreadyEmits(code.type, kind: code.kind)
            if !foreign {
                outcome.status = .resolved
                outcome.meaning = "already a default code"
                report.outcomes[key] = outcome
            }
            guard !code.sources.isEmpty else {
                if foreign { report.outcomes[key] = outcome }
                continue
            }

            var buckets: [String: MeaningBucket] = [:]
            var meant = 0
            for (id, tags) in code.sources {
                guard let tag = DefaultRuleBook.meaning(of: tags) else { continue }
                meant += 1
                let lines = rules.lines(for: tag, kind: code.kind)
                // Keyed by the rule the meaning opens, so two spellings of one rule are
                // one meaning. Not by the code it emits: one code may draw several things.
                let bucket = lines.map { "\(code.kind.rawValue)@\($0[0].text)" }
                    ?? "\(code.kind.rawValue)=\(tag)"
                buckets[bucket, default: MeaningBucket(lines: lines ?? [])].tags[tag, default: 0] += 1
                buckets[bucket]?.ids.insert(id)
                if let zoom = code.sourceZoom[id] {
                    buckets[bucket]?.resolutions[Int(zoom), default: 0] += 1
                }
            }
            read.append(CodeReading(key: key, code: code, buckets: buckets, meant: meant,
                                    foreign: foreign))
        }
        return read
    }

    /// Step four: one foreign code, resolved. Its chosen meanings become claims on the
    /// rules that already draw them, or additions where no rule exists; what could not
    /// be chosen is recorded in the outcome and nothing else happens.
    private static func resolve(_ entry: CodeReading, leader: [String: Int],
                                tagLeader: [String: Int],
                                bucketFinest: [String: Int],
                                ground: [String: Int],
                                claimed: inout [String: ClaimedRule],
                                additions: inout [ElementDumper.Kind: [RuleAddition]],
                                readByCode: [String: CodeReading],
                                verdicts: inout [String: CodeVerdict])
        -> Outcome {
        let code = entry.code
        var outcome = Outcome(kind: code.kind, type: code.type,
                              witnesses: code.sources.count, elements: code.elements,
                              unmatched: code.unmatched, ambiguous: code.ambiguous,
                              meaning: "", status: .mixed, resolutions: code.resolutions)

        let ranked = entry.buckets.sorted {
            ($0.value.count, $1.key) > ($1.value.count, $0.key)
        }
        outcome.meaning = ranked.prefix(3)
            .map { "\($0.value.name) ×\($0.value.count)" }.joined(separator: ", ")

        // Every way of giving up below is one of two: too little seen, or too much
        // disagreement, settled by how much was seen.
        outcome.status = entry.meant < scarce ? .singleWitness : .mixed
        guard code.sources.count >= 2 else {
            outcome.status = .singleWitness
            return outcome
        }
        // Elements matched to sources that mean nothing witness nothing; half of
        // them meaning nothing makes the code's matches untrustworthy.
        guard entry.meant >= 2, entry.meant * 2 >= code.sources.count else { return outcome }

        guard let chosen = chooseMeanings(of: entry, ranked: ranked,
                                          tagLeader: tagLeader, ground: ground,
                                          outcome: &outcome)
        else { return outcome }

        // Understood; a line in the sheet is another question. A meaning belongs to
        // the code that draws most of it, and the lesser code is left alone.
        outcome.status = .resolved
        verdicts[codeKey(code.kind, code.type)] = CodeVerdict(
            agrees: chosen.contains { $0.value.lines.contains { $0.emits(code.type) } },
            meaning: outcome.meaning)
        let mine = chosen.filter { pair in
            if Double(pair.value.count)
                >= stray * Double(leader[pair.key] ?? pair.value.count) { return true }
            // A zoomed-out stroke draws the same meaning where the busy code does not,
            // so it is measured against nobody: far fewer elements survive a coarse
            // zoom, and that is the point of the stroke, not a sign of a stray. It has
            // to be what the code is mostly for, though — a hatch drawn over a reserve
            // brushes the woods inside it, and that overlap is not a stroke for woods.
            if let finest = entry.code.resolutions.keys.max(),
               let drawn = bucketFinest[pair.key], finest < drawn,
               pair.value.count >= fewestWitnesses * 4,
               Double(pair.value.count) >= stray * Double(entry.meant) { return true }
            // A stray on the chain may still own one of its tags outright: the code
            // drawing most of the map's bollards is no stray under the gates.
            return pair.value.tags.contains { tag, count in
                count >= fewestWitnesses
                    && count >= tagLeader["\(code.kind.rawValue)@\(tag)"] ?? count
            }
        }
        if mine.isEmpty { outcome.meaning += " — another code draws these" }
        for (bucket, meaning) in mine {
            // No rule emits this meaning, so the code cannot be re-aimed at one: it
            // gets a rule of its own, written from what the witnesses agree it draws.
            guard !meaning.lines.isEmpty else {
                for (tag, witnesses) in meaning.tags.sorted(by: { $0.key < $1.key })
                where witnesses >= entry.floor
                    || (witnesses >= fewestWitnesses * 2
                        && witnesses >= tagLeader[
                            "\(code.kind.rawValue)@\(tag)"] ?? witnesses) {
                    additions[code.kind, default: []].append(
                        RuleAddition(tag: tag, key: String(tag.split(separator: "=")[0]),
                                     type: code.type, witnesses: witnesses,
                                     ids: meaning.ids,
                                     resolutions: meaning.resolutions))
                }
                continue
            }
            for line in meaning.lines where !line.emits(code.type) {
                // A line whose own code was seen drawing these very tags stands: the
                // map really does split the meaning across both codes. Witnessed for
                // OTHER tags of the same chain, the line is still claimed — rivers on
                // one code and canals on another is a split, not an agreement — and
                // the rule splitter hands each code its own alternatives.
                if !entry.foreign,
                   let own = Int(line.code, radix: 16),
                   let held = readByCode[codeKey(code.kind, own)]?.buckets[bucket],
                   held.count >= fewestWitnesses,
                   held.tags.contains(where: { tag, count in
                       count >= fewestWitnesses && (meaning.tags[tag] ?? 0) > 0
                   }) { continue }
                // Keyed by file AND text: the same spelling in `lines` and
                // `polygons` is two different rules.
                let slot = line.file + ":" + line.text
                var claim = claimed[slot] ?? ClaimedRule(lines: [line])
                claim.codes.append((code.type, meaning.count, meaning.ids, meaning.tags,
                                    meaning.resolutions))
                claimed[slot] = claim
            }
        }
        return outcome
    }

    /// Which of a code's meanings the sheet should honour: every one above the noise
    /// floor that has a rule, earns its own, or belongs to a family that earned one —
    /// and where those cover too little, one whole family if a single key accounts for
    /// what `purity` asks. nil when the code stays unresolved.
    private static func chooseMeanings(of entry: CodeReading,
                                       ranked: [(key: String, value: MeaningBucket)],
                                       tagLeader: [String: Int],
                                       ground: [String: Int],
                                       outcome: inout Outcome)
        -> [(key: String, value: MeaningBucket)]? {
        // A foreign code may stand for more than one rule, and may give a whole
        // family one mark. Every meaning above the noise floor is a claim — and so is
        // one below it that this code nonetheless leads: a hundred gardens are not
        // noise on a code that also draws every meadow, when nothing else draws
        // gardens at all.
        let floor = entry.floor
        func leads(_ bucket: MeaningBucket) -> Bool {
            bucket.tags.contains { tag, count in
                count >= fewestWitnesses * 2
                    && count >= tagLeader["\(entry.code.kind.rawValue)@\(tag)"] ?? count
                    // Leading a tag nobody else claims is worth nothing where the tag
                    // is everywhere and the claim is a handful: a style that draws a
                    // thing draws most of them.
                    && Double(count) >= drawnShare * Double(ground[tag] ?? count)
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
        let families = Set(above.filter {
            $0.value.lines.isEmpty
                && Double($0.value.count) >= ownRule * Double(entry.meant)
        }.map { Self.key(of: $0.value.name) })
        // A family's long tail rides in with the family: their map that draws every
        // power tower also draws its poles, however few of them the floor would pass.
        for pair in ranked
        where pair.value.count < floor && pair.value.count >= fewestWitnesses * 2
            && families.contains(Self.key(of: pair.value.name)) && leads(pair.value) {
            above.append(pair)
        }
        let wanted = above.filter { pair in
            !pair.value.lines.isEmpty
                || Double(pair.value.count) >= ownRule * Double(entry.meant)
                || families.contains(Self.key(of: pair.value.name))
                || (entry.code.kind == .point && leads(pair.value))
        }
        let covered = wanted.reduce(0) { $0 + $1.value.count }
        // Purity is asked over the plausible witnesses only: a meaning with no rule of
        // this kind and no hope of earning one is identification noise — a fence
        // matched onto the yard it encloses — not a rival reading of the code.
        let implausible = above.filter {
            $0.value.lines.isEmpty
                && !families.contains(Self.key(of: $0.value.name))
                && Double($0.value.count) < ownRule * Double(entry.meant)
        }.reduce(0) { $0 + $1.value.count }
        let plausible = max(1, entry.meant - implausible)
        if !wanted.isEmpty, Double(covered) / Double(plausible) >= purity {
            return wanted
        }

        // One mark for a whole family: no single meaning holds the code, but one
        // key accounts for what `purity` asks of a meaning. The sheet takes the
        // members above the floor; the tail keeps the default rules.
        let keyed = Dictionary(grouping: ranked) { Self.key(of: $0.value.name) }
        let family = keyed.filter { !$0.key.isEmpty }
            .max { a, b in
                a.value.reduce(0) { $0 + $1.value.count }
                    < b.value.reduce(0) { $0 + $1.value.count }
            }
        let held = family?.value.reduce(0) { $0 + $1.value.count } ?? 0
        guard entry.meant >= scarce, let family,
              Double(held) / Double(plausible) >= purity else {
            if let led = mopUp(of: entry, ranked: ranked, tagLeader: tagLeader,
                               outcome: &outcome) {
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
    /// the code leads outright — nothing else of this kind draws the tag — is honoured,
    /// with a rule to re-aim or a rule to add.
    private static func mopUp(of entry: CodeReading,
                              ranked: [(key: String, value: MeaningBucket)],
                              tagLeader: [String: Int],
                              outcome: inout Outcome)
        -> [(key: String, value: MeaningBucket)]? {
        let led = ranked.filter { pair in
            pair.value.tags.contains { tag, count in
                count >= fewestWitnesses * 2
                    && count >= tagLeader["\(entry.code.kind.rawValue)@\(tag)"] ?? count
            }
        }
        guard led.count >= 5 else { return nil }
        outcome.meaning += " — a mop-up mark, honoured where it leads"
        return led
    }

    /// Step five — invert: for each rule line, the strongest claim keeps the routing
    /// attributes and closes the rule; every other claim becomes a continue layer
    /// above it.
    private static func claimedRuleSheet(
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
            guard let line = entry.lines.first else { continue }
            // One meaning, one stroke per zoom: at each resolution the code their map
            // mostly draws this meaning with owns that zoom, and the rest keep quiet
            // there. Without this a rare variant — a via ferrata among paths, a
            // reserve's hatch over the woods inside it — would paint every one of them.
            byType = ownedZooms(byType)
            // A style may keep a second, thinner vocabulary for the zoomed-out levels:
            // a motorway is a stroke six pixels wide up close and one pixel wide on the
            // overview, under a different code. Such a code is told from the detailed
            // one by where each was seen — the zoomed-out stroke stops before the
            // finest zoom the rule is drawn at — and is written as a line of its own
            // over the range it belongs to, rather than stacked everywhere.
            let finest = byType.values.compactMap { $0.resolutions.keys.max() }.max()
            let overview = byType.values.filter { claim in
                guard let finest, let highest = claim.resolutions.keys.max() else {
                    return false
                }
                return highest < finest
            }.sorted { ($0.weight, $0.type) > ($1.weight, $1.type) }
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
            // a layer of it would draw the same stroke twice — two plain road lines
            // under their extended one, thicker and in the plain colour.
            let layers = line.isSplit ? [] : ranked.dropFirst().reversed()
                .filter { paintsTheSame($0.ids, base.ids) && !line.emits($0.type) }
            // The rule's own code holds the line and nothing is painted over it: the
            // line stays as it is — unless a zoomed-out stroke wants a line of its own.
            if line.emits(base.type), layers.isEmpty, overview.isEmpty { continue }
            sheet.append("@@ \(line.file)")
            sheet.append("- \(line.text)")
            // A rule written over two lines is REPLACED over two lines: both go into the
            // anchor, or mkgmap refuses the style with "Stack size is 0".
            if let second = line.continuation { sheet.append("- \(second)") }
            // Order is what a receiver draws by: the elements of one way are painted in
            // the order the rules add them, so what comes last lies on top. The
            // borrowed map does the same — a bridge's casing first, the road over it —
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
            // would write that number a second time, without the routing attributes —
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

    /// The plain numbers Garmin routes on. Only these carry routing, so only a rule
    /// meant to be routable may emit one.
    private static func routable(_ type: Int) -> Bool { type >= 0x01 && type <= 0x16 }

    /// Notes how a code came out painted, so the rules this pass never saw can be
    /// painted the same way. The strongest reading wins where two rules disagree: the
    /// one whose strokes were seen on the most elements.
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
    /// the ways carrying that tag were counted as trunk roads — so the trunk rule
    /// learned the ladder and the roundabout rule, drawn on the same blank number,
    /// learned nothing and came out invisible. Any rule closing on a code whose ladder
    /// is known gets that ladder, banded exactly as the witnessed rule's was.
    private static func siblingRuleSheet(
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
    private static func additionSheet(_ additions: [ElementDumper.Kind: [RuleAddition]],
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
            // this kind has no rules of its own under — an addition goes above the
            // whole file, and a wildcard there would shadow every dedicated rule.
            var collapsed: [RuleAddition] = []
            var taken = Set<String>()
            for addition in ordered {
                let familyKey = addition.key + "@" + String(addition.type)
                let members = ordered.filter {
                    $0.key + "@" + String($0.type) == familyKey
                }
                if members.count >= 3, !rules.hasRules(key: addition.key, kind: kind) {
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
                            }))
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
                // drawn — every building outline, and no building. Where our rules
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
                if let low = addition.resolutions.keys.min(),
                   let high = addition.resolutions.keys.max() {
                    band = "\(low)-\(high)"
                } else {
                    band = "\(resolution)"
                }
                sheet.append(String(format: "+ %@ [0x%02x resolution %@%@]",
                                    addition.tag, addition.type, band,
                                    layered || overAnArea ? " continue" : ""))
            }
            sheet.append("+ \(anchor)")
        }
        return sheet
    }

    /// The key of a tag pair: `building` of `building=house`.
    private static func key(of tag: String) -> String {
        String(tag.split(separator: "=").first ?? "")
    }

    /// Splits one rule into one rule per claiming code, each taking exactly the
    /// alternatives its code was seen drawing; alternatives no code was seen on stay
    /// with the strongest claimant. Only for a condition of the safe shape — a leading
    /// parenthesised group of bare pairs — and only when at least two codes own at
    /// least one alternative each; anything else returns nil and the rule is rewritten
    /// whole, as before.
    private static func splitRule(
        _ line: DefaultRuleBook.Line,
        ranked: [(type: Int, weight: Int, ids: Set<Int64>, tags: [String: Int],
                  resolutions: [Int: Int])])
        -> [String]? {
        if line.leadingGroup() == nil, line.wildcardHead() != nil {
            return splitFamilyRule(line, ranked: ranked)
        }
        guard let (pairs, span) = line.leadingGroup() else { return nil }
        // Each alternative goes to the code with most witnesses for its tag.
        var owner: [String: Int] = [:]
        for pair in pairs {
            var bestType: Int?
            var bestCount = fewestWitnesses - 1
            for claim in ranked {
                if let count = claim.tags[pair], count > bestCount {
                    bestCount = count
                    bestType = claim.type
                }
            }
            if let bestType { owner[pair] = bestType }
        }
        var byOwner: [Int: [String]] = [:]
        for pair in pairs {
            byOwner[owner[pair] ?? ranked[0].type, default: []].append(pair)
        }
        guard byOwner.count > 1 else { return nil }
        var out = ["@@ \(line.file)", "- \(line.text)"]
        if let second = line.continuation { out.append("- \(second)") }
        // The strongest claimant goes last, keeping the file's reading order stable.
        for (type, taken) in byOwner.sorted(by: { ($0.value.count, $1.key)
                                                  < ($1.value.count, $0.key) }) {
            out.append(contentsOf: line.replacementSplitting(
                group: taken, span: span, to: type).map { "+ \($0)" })
        }
        return out
    }

    /// Splits a family rule — `shop=* & name=*` — by dedication: each claimant that
    /// leads concrete tags of the family gets a dedicated rule above it, and the
    /// family itself keeps the strongest claim for everything else. mkgmap reads top
    /// down, so the dedicated rules win exactly their own tags.
    private static func splitFamilyRule(
        _ line: DefaultRuleBook.Line,
        ranked: [(type: Int, weight: Int, ids: Set<Int64>, tags: [String: Int],
                  resolutions: [Int: Int])])
        -> [String]? {
        guard let base = ranked.first else { return nil }
        var dedicated: [(pair: String, type: Int)] = []
        for claim in ranked.dropFirst() {
            // The tags this code owns outright within the family's claims.
            for (tag, count) in claim.tags.sorted(by: { $0.key < $1.key })
            where count >= fewestWitnesses * 2
                && !ranked.contains(where: { $0.type != claim.type
                    && ($0.tags[tag] ?? 0) > count }) {
                dedicated.append((tag, claim.type))
            }
        }
        guard !dedicated.isEmpty else { return nil }
        var out = ["@@ \(line.file)", "- \(line.text)"]
        if let second = line.continuation { out.append("- \(second)") }
        for (pair, type) in dedicated {
            out.append(contentsOf: line.replacementDedicating(pair: pair, to: type)
                .map { "+ \($0)" })
        }
        out.append(contentsOf: line.replacement(to: base.type).map { "+ \($0)" })
        return out
    }

    /// Keeps, for each code, only the zooms at which it draws this meaning more than
    /// any other code does — or at which it was painted over the same elements as the
    /// code that does, which makes the two layers of one drawing rather than rivals.
    /// A style whose plain road types are blank paints every road twice, once on the
    /// routable number and once on the stroke that shows: dropping the loser there
    /// would leave the road routable and invisible.
    ///
    /// A code left owning nothing is dropped: their map draws the meaning some other
    /// way there, and painting both would stack two looks.
    private static func ownedZooms(
        _ byType: [Int: (type: Int, weight: Int, ids: Set<Int64>, tags: [String: Int],
                         resolutions: [Int: Int])])
        -> [Int: (type: Int, weight: Int, ids: Set<Int64>, tags: [String: Int],
                  resolutions: [Int: Int])] {
        guard byType.count > 1 else { return byType }
        var owner: [Int: Int] = [:]      // zoom -> code
        var best: [Int: Int] = [:]       // zoom -> that code's count there
        for claim in byType.values {
            for (zoom, count) in claim.resolutions where count > (best[zoom] ?? 0) {
                best[zoom] = count
                owner[zoom] = claim.type
            }
        }
        var out: [Int: (type: Int, weight: Int, ids: Set<Int64>, tags: [String: Int],
                        resolutions: [Int: Int])] = [:]
        for (type, claim) in byType {
            let kept = claim.resolutions.filter { zoom, _ in
                guard owner[zoom] != type else { return true }
                guard let over = owner[zoom], let held = byType[over] else { return false }
                return paintsTheSame(claim.ids, held.ids)
            }
            guard !kept.isEmpty else { continue }
            out[type] = (claim.type, claim.weight, claim.ids, claim.tags, kept)
        }
        // A code with no zooms recorded at all — a point matched only at the detailed
        // level — keeps its claim: there is nothing to divide.
        return out.isEmpty ? byType : out
    }

    /// The strokes, then the rule that closes the chain.
    ///
    /// Order was tried the other way — the rule first, so the borrowed paint would lie
    /// on top — and it leaks: a stroke pinned to a band does not match outside it, so
    /// at those zooms the chain runs on into the rules below and picks up whatever they
    /// draw. The rule goes last, where it stops the search, as mkgmap's own rules do.
    private static func keeping(_ rule: DefaultRuleBook.Line,
                                under strokes: [String]) -> [String] {
        keeping(rule.continuation.map { [rule.text, $0] } ?? [rule.text],
                under: strokes)
    }

    private static func keeping(_ rule: [String], under strokes: [String]) -> [String] {
        (strokes + rule).map { "+ " + $0 }
    }

    /// The line that closes the chain, pinned to the zooms its own code owns.
    ///
    /// A ladder hands each zoom to one code, but the closing line keeps the rule's own
    /// `resolution N`, which means N and every zoom finer — so where a stroke owns the
    /// zoom, the base code draws underneath it as well. On a road that costs nothing,
    /// since their plain numbers are blank; on water, whose plain number is a drawn
    /// line, the two stack and the river comes out wider than the map it was learned
    /// from. Left alone where the line carries routing: a road is routed on its number
    /// at every zoom, whatever is drawn over it.
    ///
    /// The band never reaches past where the rule already drew: a code seen at a zoom
    /// the rule does not draw at says something about their map, not about ours.
    private static func closing(_ lines: [String], of line: DefaultRuleBook.Line,
                                owning resolutions: [Int: Int],
                                under strokes: [String]) -> [String] {
        guard !strokes.isEmpty, !lines.isEmpty,
              !(line.text + (line.continuation ?? "")).contains("road_class="),
              var low = resolutions.keys.min(), let high = resolutions.keys.max()
        else { return lines }
        var out = lines
        let last = out.count - 1
        if let own = out[last].firstCapture("resolution ([0-9]+)").flatMap({ Int($0) }) {
            low = max(low, own)
        }
        guard low <= high else { return lines }
        out[last] = out[last].replacingOccurrences(
            of: "resolution [0-9-]+", with: "resolution \(low)-\(high)",
            options: .regularExpression)
        return out
    }

    /// One stroke of a rule's ladder: the rule's line re-aimed to `type` and pinned to
    /// the band of zooms that code was actually seen at. Without a band the stroke
    /// would also draw at every finer zoom, where another stroke of the same ladder
    /// belongs. A code with no recorded zooms keeps the rule's own resolution.
    private static func banded(_ line: DefaultRuleBook.Line, to type: Int,
                               resolutions: [Int: Int]) -> String {
        let layered = line.layered(to: type)
        guard let low = resolutions.keys.min(),
              let high = resolutions.keys.max() else { return layered }
        return layered.replacingOccurrences(of: "resolution [0-9-]+",
                                            with: "resolution \(low)-\(high)",
                                            options: .regularExpression)
    }

    /// Whether two codes were painted over the same elements, making them two layers of
    /// one drawing, or over different ones, making them two kinds.
    private static func paintsTheSame(_ one: Set<Int64>, _ other: Set<Int64>) -> Bool {
        let smaller = min(one.count, other.count)
        guard smaller > 0 else { return false }
        return Double(one.intersection(other).count) / Double(smaller) >= sameElements
    }
}
