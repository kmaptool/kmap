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
    /// Their icon for a lift gate was seen eleven times over a pedestrian crossing -
    /// a gate sits near one - and nothing else drew crossings, so eleven witnesses
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

    /// A zoomed-out stroke needs this many: it is measured against nobody, since far
    /// fewer elements survive a coarse zoom, so the bar is its own.
    static let fewestStroke = fewestWitnesses * 4

    /// To lead a tag outright, or earn a rule below the floor, a meaning needs this many.
    static let fewestOutright = fewestWitnesses * 2

    /// The mop-up verdict needs this many led meanings; fewer is a coincidence.
    static let fewestLed = 5

    /// This many members of one key on one code become one family rule.
    static let fewestFamily = 3

    /// One meaning, as the default rules see it, and the witnesses a foreign code
    /// gave it. Keyed per rule rather than per tag: two tags that open one rule are
    /// one meaning. A meaning with no rule keeps its tag as its own key.
    struct MeaningBucket {
        var lines: [DefaultRuleBook.Line]
        var tags: [String: Int] = [:]
        /// How many of this meaning's witnesses were seen at each zoom, so a ladder is
        /// read per zoom: one meaning, one stroke at a time.
        var resolutions: [Int: Int] = [:]
        /// The witnesses themselves: shared elements make two codes two layers of
        /// one drawing rather than two kinds.
        var ids: Set<Int64> = []
        var count: Int { ids.count }
        /// How many of them carry `building=*`: a substation building and a
        /// substation yard share a tag, and a style may draw them apart.
        var built = 0
        var isBuilt: Bool { built * 2 > count }
        /// The commonest tag in it: what the report shows, and what a rule written
        /// for it is written from.
        var name: String {
            tags.max { ($0.value, $1.key) < ($1.value, $0.key) }?.key ?? ""
        }
    }

    /// What one foreign code's witnesses meant, before anything has been decided.
    struct CodeReading {
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
    struct ClaimedRule {
        let lines: [DefaultRuleBook.Line]
        var codes: [(type: Int, weight: Int, ids: Set<Int64>, tags: [String: Int],
                     resolutions: [Int: Int])] = []
    }

    /// A rule the style does not have, to be written for a code that needs one.
    struct RuleAddition {
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
        /// Written with `& building!=*`: their map draws the buildings carrying this
        /// tag as buildings, and only the open ground this way.
        var openOnly = false
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
        // chain, yet the rightful owner of its own tag - bollards under the gates.
        var tagLeader: [String: Int] = [:]
        // The finest zoom each meaning is drawn at, over every code: a stroke that
        // stops short of it is the same meaning at another zoom, not a stray.
        var bucketFinest: [String: Int] = [:]
        // And per class, buildings apart from open ground: a yard is no stray of the
        // buildings standing in it.
        var classLeader: [String: Int] = [:]
        var builtMost: [String: Int] = [:], openMost: [String: Int] = [:]
        for entry in read {
            for (bucket, meaning) in entry.buckets {
                leader[bucket] = max(leader[bucket] ?? 0, meaning.count)
                let classed = classKey(bucket, meaning)
                classLeader[classed] = max(classLeader[classed] ?? 0, meaning.count)
                if let finest = entry.code.resolutions.keys.max() {
                    bucketFinest[bucket] = max(bucketFinest[bucket] ?? 0, finest)
                }
                for (tag, count) in meaning.tags {
                    tagLeader["\(entry.code.kind.rawValue)@\(tag)"]
                        = max(tagLeader["\(entry.code.kind.rawValue)@\(tag)"] ?? 0, count)
                    guard entry.code.kind == .area else { continue }
                    let key = "\(entry.code.kind.rawValue)@\(tag)"
                    if meaning.isBuilt {
                        builtMost[key] = max(builtMost[key] ?? 0, count)
                    } else {
                        openMost[key] = max(openMost[key] ?? 0, count)
                    }
                }
            }
        }
        // A tag is drawn on buildings, or on open ground, only where that class is
        // a real share of it: three mistagged houses do not make the woods built.
        func real(_ mine: Int?, against other: Int?) -> Bool {
            let mine = mine ?? 0
            return mine >= fewestStroke && Double(mine) >= stray * Double(other ?? 0)
        }
        let builtTags = Set(builtMost.keys.filter { real(builtMost[$0], against: openMost[$0]) })
        let openTags = Set(openMost.keys.filter { real(openMost[$0], against: builtMost[$0]) })

        var claimed: [String: ClaimedRule] = [:]
        var additions: [ElementDumper.Kind: [RuleAddition]] = [:]
        // Rules their map draws on buildings as buildings, and on open ground its
        // own way: narrowed to the ground, so the buildings fall through.
        var narrowed: [String: DefaultRuleBook.Line] = [:]

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

        // Every witnessed code resolves - a foreign number and a colliding one alike. A
        // number the default set also uses is no promise the foreign style means the
        // same thing by it: this map drew barracks as 0x1c, which is kmap's farmland.
        // The same evidence, reachable by code: a claim asks whether a line's own
        // code was itself seen drawing the meaning before re-aiming the line away.
        var readByCode: [String: CodeReading] = [:]
        for entry in read { readByCode[codeKey(entry.code.kind, entry.code.type)] = entry }

        var verdicts: [String: CodeVerdict] = [:]
        for entry in read {
            var outcome = resolve(entry, leader: leader, classLeader: classLeader,
                                  tagLeader: tagLeader, builtTags: builtTags,
                                  openTags: openTags,
                                  bucketFinest: bucketFinest, ground: ground,
                                  claimed: &claimed, narrowed: &narrowed,
                                  additions: &additions, readByCode: readByCode,
                                  verdicts: &verdicts)
            if !entry.foreign {
                outcome.meaning = outcome.meaning.isEmpty
                    ? "a default code" : outcome.meaning + " — a default code too"
            }
            report.outcomes[entry.key] = outcome
        }

        // Rule chains the foreign map was seen drawing, per kind: a rule of a drawn
        // chain is never silenced - the claims have already said what happens to it.
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
        // elsewhere - whichever order the rules happen to be in.
        var ladders: [String: [(type: Int, resolutions: [Int: Int])]] = [:]
        _ = claimedRuleSheet(claimed, ladders: &ladders)
        let learned = ladders
        var sheet = claimedRuleSheet(claimed, ladders: &ladders, known: learned)
        for (slot, line) in narrowed.sorted(by: { $0.key < $1.key })
        where claimed[slot] == nil {
            guard let open = line.narrowedToOpenGround() else { continue }
            sheet.append("@@ \(line.file)")
            sheet.append("- \(line.text)")
            if let second = line.continuation { sheet.append("- \(second)") }
            sheet.append(contentsOf: open.map { "+ " + $0 })
            claimed[slot] = ClaimedRule(lines: [line])
        }
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
    /// meaning already emits the code - the two vocabularies agreeing on the number -
    /// and the words for the comment when they do not.
    struct CodeVerdict {
        let agrees: Bool
        let meaning: String
    }

    static func codeKey(_ kind: ElementDumper.Kind, _ type: Int) -> String {
        "\(kind.rawValue):\(String(type, radix: 16))"
    }

    /// A bucket's key within its class: buildings and open ground compete apart.
    static func classKey(_ bucket: String, _ meaning: MeaningBucket) -> String {
        bucket + (meaning.isBuilt ? "#built" : "#open")
    }

    /// A zoom seen fewer than `fewestWitnesses` times is not a zoom the code draws
    /// at; the most seen one stays, so a band never comes out empty.
    static func steadyZooms(_ resolutions: [Int: Int]) -> [Int: Int] {
        guard let most = resolutions.values.max() else { return resolutions }
        return resolutions.filter { $0.value >= fewestWitnesses || $0.value == most }
    }

    /// The plain numbers Garmin routes on. Only these carry routing, so only a rule
    /// meant to be routable may emit one.
    static func routable(_ type: Int) -> Bool { type >= 0x01 && type <= 0x16 }

    /// The key of a tag pair: `building` of `building=house`.
    static func key(of tag: String) -> String {
        String(tag.split(separator: "=").first ?? "")
    }

    /// Whether two codes were painted over the same elements, making them two layers of
    /// one drawing, or over different ones, making them two kinds.
    static func paintsTheSame(_ one: Set<Int64>, _ other: Set<Int64>) -> Bool {
        let smaller = min(one.count, other.count)
        guard smaller > 0 else { return false }
        return Double(one.intersection(other).count) / Double(smaller) >= sameElements
    }
}
