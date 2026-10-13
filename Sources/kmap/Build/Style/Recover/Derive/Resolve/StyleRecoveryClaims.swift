import Foundation

extension StyleRecovery {
    /// What resolving the codes settled: the rules claimed and by whom, the rules narrowed
    /// to open ground, the rules to add, and what each code was read as.
    struct Claims {
        /// Each rule line, keyed by file AND text, with every code laying claim to it: the
        /// same spelling in `lines` and `polygons` is 2 different rules.
        private(set) var rules: [String: ClaimedRule] = [:]
        /// Rules their map draws on buildings as buildings, and on open ground its own
        /// way: narrowed to the ground, so the buildings fall through.
        private(set) var narrowed: [String: DefaultRuleBook.Line] = [:]
        /// Rules no default line has, per kind.
        private(set) var additions: [ElementDumper.Kind: [RuleAddition]] = [:]
        /// Per code: whether it agrees with the rules it was seen on, and what it means.
        private(set) var verdicts: [String: CodeVerdict] = [:]

        /// A default code claims the lines it already emits: a foreign code painted over
        /// the same elements then becomes a layer above it, not a replacement or a stray.
        init(defaultsOf readings: [CodeReading]) {
            for entry in readings where !entry.foreign {
                for (_, meaning) in entry.buckets where meaning.count >= entry.floor {
                    for line in meaning.lines where line.emits(entry.code.type) {
                        claim(line, by: entry.code.type, meaning: meaning)
                    }
                }
            }
        }

        /// A code's claim on a rule line, with what it was seen drawing there.
        mutating func claim(_ line: DefaultRuleBook.Line, by type: Int, meaning: MeaningBucket) {
            rules[line.file + ":" + line.text, default: ClaimedRule(lines: [line])].codes.append(
                (type, meaning.count, meaning.ids, meaning.tags, meaning.resolutions)
            )
        }

        mutating func narrow(_ line: DefaultRuleBook.Line) {
            narrowed[line.file + ":" + line.text] = line
        }

        mutating func add(_ addition: RuleAddition, kind: ElementDumper.Kind) {
            additions[kind, default: []].append(addition)
        }

        mutating func judge(_ code: String, _ verdict: CodeVerdict) {
            verdicts[code] = verdict
        }
    }
}
