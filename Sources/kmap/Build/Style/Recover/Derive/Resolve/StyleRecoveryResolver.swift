import Foundation

extension StyleRecovery {
    /// Resolves the codes read into claims on kmap's rules. Every code is weighed against
    /// the strongest claim made on each of its meanings, over all the codes.
    struct Resolver {
        /// The codes read, each bucket's rules widened by the tags the code leads.
        let readings: [CodeReading]
        let leaders: Leaders
        let builtTags: Set<String>
        let openTags: Set<String>
        /// The same readings by code: a claim asks whether a line's own code was itself
        /// seen drawing the meaning before re-aiming the line away.
        let readByCode: [String: CodeReading]
        /// How many things carrying each meaning the compared ground holds, so a claim can
        /// be weighed against what there was to draw.
        let ground: [String: Int]
        private(set) var claims: Claims

        init(readings raw: [CodeReading], rules: DefaultRuleBook, ground: [String: Int]) {
            let leaders = Leaders(of: raw)
            let readings = raw.map { StyleRecovery.widened($0, rules: rules, tagLeader: leaders.tag) }
            self.readings = readings
            self.leaders = leaders
            (builtTags, openTags) = leaders.classedTags()
            var byCode: [String: CodeReading] = [:]
            for entry in readings { byCode[StyleRecovery.codeKey(entry.code.kind, entry.code.type)] = entry }
            readByCode = byCode
            self.ground = ground
            claims = Claims(defaultsOf: readings)
        }

        /// Rule chains the foreign map was seen drawing, per kind: a rule of a drawn chain
        /// is never silenced - the claims have already said what happens to it.
        var witnessedSlots: Set<String> {
            var slots = Set<String>()
            for entry in readings {
                for (_, bucket) in entry.buckets where bucket.count >= StyleRecovery.fewestWitnesses {
                    for line in bucket.lines {
                        slots.insert("\(entry.code.kind.rawValue):\(line.file):\(line.text)")
                    }
                }
            }
            return slots
        }

        /// 1 code, resolved. Its chosen meanings become claims on the rules that already
        /// draw them, or additions where no rule exists; what could not be chosen is
        /// recorded in the outcome and nothing else happens.
        mutating func resolve(_ entry: CodeReading) -> Outcome {
            let code = entry.code
            var outcome = Outcome(
                kind: code.kind,
                type: code.type,
                witnesses: code.sources.count,
                elements: code.elements,
                unmatched: code.unmatched,
                ambiguous: code.ambiguous,
                meaning: "",
                status: .mixed,
                resolutions: code.resolutions
            )

            let ranked = entry.buckets.sorted {
                ($0.value.count, $1.key) > ($1.value.count, $0.key)
            }
            // By tag: one tag may open several rule lines, a volcano and an active one.
            var byTag: [String: Int] = [:]
            for (_, bucket) in ranked { byTag[bucket.name, default: 0] += bucket.count }
            outcome.meaning = byTag.sorted { ($0.value, $1.key) > ($1.value, $0.key) }.prefix(3)
                .map { "\($0.key) ×\($0.value)" }.joined(separator: ", ")

            // Every way of giving up below is 1 of 2: too little seen, or too much
            // disagreement, settled by how much was seen.
            outcome.status = entry.meant < StyleRecovery.scarce ? .singleWitness : .mixed
            guard code.sources.count >= 2 else {
                outcome.status = .singleWitness
                return outcome
            }
            // Elements matched to sources that mean nothing witness nothing; half of
            // them meaning nothing makes the code's matches untrustworthy.
            guard entry.meant >= 2, entry.meant * 2 >= code.sources.count else { return outcome }

            guard
                let chosen = chooseMeanings(
                    of: entry,
                    ranked: ranked,
                    outcome: &outcome
                )
            else { return outcome }

            // Understood; a line in the sheet is another question. A meaning belongs to
            // the code that draws most of it, and the lesser code is left alone.
            outcome.status = .resolved
            claims.judge(
                StyleRecovery.codeKey(code.kind, code.type),
                CodeVerdict(
                    agrees: chosen.contains { $0.value.lines.contains { $0.emits(code.type) } },
                    meaning: outcome.meaning
                )
            )
            let mine = chosen.filter { isOwn($0, of: entry) }
            if mine.isEmpty { outcome.meaning += " — another code draws these" }
            for (bucket, meaning) in mine {
                place(meaning, of: bucket, for: entry)
            }
            return outcome
        }

        /// 1 of a code's own meanings, placed: a claim on the rules that draw it, a rule
        /// narrowed to open ground, or an addition where no rule can be re-aimed.
        private mutating func place(
            _ meaning: StyleRecovery.MeaningBucket,
            of bucket: String,
            for entry: StyleRecovery.CodeReading
        ) {
            let code = entry.code
            // Open ground whose tag their map also draws on buildings, as buildings:
            // re-aiming the rule would take the buildings along, so the code gets a
            // rule of its own that leaves them to the building rule.
            let openOnly =
                !meaning.isBuilt
                && meaning.tags.keys.contains {
                    builtTags.contains("\(code.kind.rawValue)@\($0)")
                }
            let reAims = meaning.lines.contains { !$0.emits(code.type) }
            // No rule emits this meaning, so the code cannot be re-aimed at one: it
            // gets a rule of its own, written from what the witnesses agree it draws.
            guard !meaning.lines.isEmpty, !(openOnly && reAims) else {
                for (tag, witnesses) in meaning.tags.sorted(by: { $0.key < $1.key })
                where witnesses >= entry.floor
                    || (witnesses >= StyleRecovery.fewestOutright
                        && witnesses >= leaders.tag[
                            "\(code.kind.rawValue)@\(tag)"
                        ] ?? witnesses)
                {
                    claims.add(
                        StyleRecovery.RuleAddition(
                            tag: tag,
                            key: String(tag.split(separator: "=")[0]),
                            type: code.type,
                            witnesses: witnesses,
                            ids: meaning.ids,
                            resolutions: meaning.resolutions,
                            openOnly: openOnly
                        ),
                        kind: code.kind
                    )
                }
                return
            }
            // Buildings their map draws as buildings, on a rule open ground matches
            // too: the rule is narrowed to the ground rather than re-aimed whole.
            if meaning.isBuilt,
                meaning.tags.keys.contains(where: {
                    openTags.contains("\(code.kind.rawValue)@\($0)")
                })
            {
                for line in meaning.lines where !line.emits(code.type) {
                    claims.narrow(line)
                }
                return
            }
            for line in meaning.lines where !line.emits(code.type) {
                // A line whose own code was seen drawing these very tags stands: the
                // map really does split the meaning across both codes. Witnessed for
                // OTHER tags of the same chain, the line is still claimed - rivers on
                // one code and canals on another is a split, not an agreement - and
                // the rule splitter hands each code its own alternatives.
                if !entry.foreign,
                    let own = Int(line.code, radix: 16),
                    let held = readByCode[StyleRecovery.codeKey(code.kind, own)]?.buckets[bucket],
                    held.count >= StyleRecovery.fewestWitnesses,
                    held.tags.contains(where: { tag, count in
                        count >= StyleRecovery.fewestWitnesses && (meaning.tags[tag] ?? 0) > 0
                    })
                {
                    continue
                }
                claims.claim(line, by: code.type, meaning: meaning)
            }
        }
    }
}
