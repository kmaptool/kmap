import Foundation

/// Recovers a foreign map's code vocabulary as a reassignment sheet.
///
/// A compiled map keeps only codes, geometry and labels, on the 2.4 m Garmin grid. An
/// element's vertex chain names the OSM way it was compiled from, whose tags give the
/// rule line that should emit the foreign code. The output is a substitution sheet,
/// applied per style at build time.
enum StyleRecovery {

    struct Report {
        var frame = BBox.empty
        var extracts: [URL] = []
        var elements = 0
        /// key -> outcome, sorted for printing by the caller.
        var outcomes: [String: Outcome] = [:]
        /// The recovered style: their pictures on kmap's numbers. A TYP that builds,
        /// which is what a recovery is for.
        var style = ""
        /// What their style draws and kmap has no number for, worst first.
        var uncovered: [StylePort.Ported] = []
        /// How many of our numbers took a picture, by kind, for the report.
        var ported: [MapElementKind: Int] = [:]
        /// The reassignment list. Nothing needs it to build; it is for the style
        /// editor, and for a style still kept on the map's own numbers.
        var sheet = ""
        /// What the map draws each meaning with: tag -> code key -> identified sources.
        /// The raw material of `recover-check`, which compares two maps tag by tag.
        var codesByTag: [String: [String: Int]] = [:]
        /// How many objects of each meaning the searched ground holds at all — so a tag
        /// the ground never carries is not reported as a map's omission.
        var groundTags: [String: Int] = [:]
    }

    struct Outcome {
        let kind: ElementDumper.Kind
        let type: Int
        var witnesses: Int
        var elements: Int
        var unmatched: Int
        var ambiguous: Int
        /// The dominant tag pair, in readable form.
        var meaning: String
        var status: Status
        /// The resolutions this code was seen drawn at, coarsest to finest. A style
        /// with a second vocabulary for the zoomed-out levels shows here.
        var resolutions: [Int: Int] = [:]

        /// `16–18`, or nil where nothing was recorded.
        var zooms: String? {
            guard let low = resolutions.keys.min(), let high = resolutions.keys.max()
            else { return nil }
            return low == high ? "res \(low)" : "res \(low)–\(high)"
        }
    }

    /// Codes kmap manufactures rather than reads: contours from the DEM, sea and the
    /// background under it. No OSM way is their source, so no evidence can exist.
    ///
    /// The land polygon is deliberately NOT here. It rides on 0x27, and a borrowed
    /// style that paints that number paints it over every acre of the map — the one
    /// tried it as a construction hatch, and the whole country came out a building
    /// site. Land is drawn only where their vocabulary leaves the number alone, which
    /// is the same rule everything else follows.
    static let generated: Set<String> = ["L20", "L21", "L22", "A32", "A4A", "A4B"]

    enum Status: String {
        /// Two or more agreeing identifications, and a rule line found: in the sheet.
        case resolved
        /// One clean identification: in the sheet, flagged for review.
        case singleWitness = "single-witness"
        /// Witnesses agree but no default rule emits this meaning; decided by hand.
        case noRule = "no-rule"
        /// Witnesses disagree beyond the threshold; decided by hand.
        case mixed
        /// Nothing identified on the ground that was searched.
        case noEvidence = "no-evidence"
    }

    /// The whole pipeline: dump, index, match, aggregate, derive.
    ///
    /// Cancellation is the task's: it kills the reader process, and the matching loop
    /// checks between elements.
    static func run(img: URL, extracts explicit: [URL], log: Log,
                    rulesDirectory: URL? = nil,
                    progress: RecoverProgress? = nil) async throws -> Report {
        var report = Report()

        let drawn = RegionSuggestion.drawnGround(of: img)
        let frame = drawn.frame
        report.frame = frame
        guard frame.isValid else { throw Trouble.noTiles }

        // Ground truth: the extracts handed in, or every cached extract touching a tile.
        // Tiles rather than the frame: the frame spans ground a non-rectangular map
        // never draws.
        if let missing = explicit.first(where: { !FileTools.exists($0) }) {
            throw Trouble.noSuchExtract(missing)
        }
        let extracts = explicit.isEmpty
            ? RegionSuggestion.cachedExtracts(drawnOn: drawn) : explicit
        guard !extracts.isEmpty else { throw Trouble.noExtracts(frame) }
        report.extracts = extracts

        // One ground per extract, clipped to the frame: identification can happen only
        // where an extract covers the map, and one box around distant extracts would
        // read the gap between them too.
        var grounds: [BBox] = []
        for extract in extracts {
            guard let box = (try? PBFReader(url: extract).headerBBox()) ?? nil else {
                grounds = [frame]
                break
            }
            let within = BBox(minLon: box.minLon, minLat: box.minLat,
                              maxLon: box.maxLon, maxLat: box.maxLat).intersection(frame)
            if within.isValid { grounds.append(within) }
        }
        if grounds.isEmpty { grounds = [frame] }

        log.step("reading the map's elements")
        progress?.move(to: .reading)
        let dump = try ElementDumper.dump(img: img, grounds: grounds, log: log,
                                          progress: progress)
        report.elements = dump.count
        log.append("\(dump.count) element(s) at the detail level, over the ground searched")

        // One byte per element, shared by every extract: the best match any of them
        // managed. A raw buffer, not an array: cores write disjoint index ranges at once.
        let matches = UnsafeMutableBufferPointer<UInt8>.allocate(capacity: dump.count)
        matches.initialize(repeating: Evidence.Match.unmatched.rawValue)
        defer { matches.deallocate() }

        // The zoomed-out drawings too: a reserve's hatch may exist only there.
        let coarse = (try? ElementDumper.dump(img: img, grounds: grounds, log: log,
                                              coarserLevels: true)) ?? ElementDumper.Dump()

        var evidence = Evidence()
        for extract in extracts {
            try Task.checkCancellation()
            log.step("matching against \(extract.lastPathComponent)")
            progress?.move(to: .indexing(extract.lastPathComponent))
            let index = try GroundIndex(extract: extract, frame: frame)
            log.append("\(index.ways.count) tagged way(s), \(index.nodes.count) tagged node(s) in frame")
            for way in index.ways {
                if let tag = DefaultRuleBook.meaning(of: way.tags) {
                    report.groundTags[tag, default: 0] += 1
                }
            }
            for node in index.nodes {
                if let tag = DefaultRuleBook.meaning(of: node.tags) {
                    report.groundTags[tag, default: 0] += 1
                }
            }
            progress?.move(to: .matching(extract.lastPathComponent))
            progress?.count(0, of: dump.count)
            evidence.merge(try await matched(dump, against: index, matches: matches,
                                             progress: progress))
            // What geometry could not name is asked of the place — its own stage, or
            // the bar sits on a finished 100% while this works.
            progress?.move(to: .placing(extract.lastPathComponent))
            CoarseEvidence.match(coarse, index: index, into: &evidence)
            await CoarseEvidence.rescuePoints(dump, matches: matches, index: index,
                                              into: &evidence, progress: progress)
        }
        evidence.tally(dump, matches: UnsafeBufferPointer(matches))

        // Per-meaning ledger: which codes this map was seen drawing each tag with.
        for (key, code) in evidence.codes {
            for (_, tags) in code.sources {
                guard let tag = DefaultRuleBook.meaning(of: tags) else { continue }
                report.codesByTag[tag, default: [:]][key, default: 0] += 1
            }
        }

        // The TYP the map carries, for the silencing gate: only a code their TYP
        // paints can paint the wrong thing. A map without a TYP silences nothing.
        var typDefined: [ElementDumper.Kind: Set<Int>] = [:]
        let typScratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("recover-\(UUID().uuidString).typ")
        if ImgContainer.extractTYP(from: img, to: typScratch),
           let typ = try? TypBinary.read(typScratch) {
            typDefined[.area] = Set(typ.polygons.map(\.code))
            typDefined[.line] = Set(typ.lines.map(\.code))
            typDefined[.point] = Set(typ.points.map(\.code))
        }
        FileTools.removeIfPresent(typScratch)

        progress?.move(to: .deriving)
        let rules = rulesDirectory.map { DefaultRuleBook.load(from: $0) } ?? DefaultRuleBook.load()
        derive(evidence, into: &report, rules: rules, typDefined: typDefined,
               ground: report.groundTags)
        recoverStyle(from: img, into: &report, log: log)
        return report
    }

    /// Their look on kmap's numbers, as a TYP source. The pictures come from the TYP
    /// the map carries; which lands on which of our numbers is the evidence's to say.
    /// Silent where there is nothing to recover, or no rules of ours to put it on.
    private static func recoverStyle(from img: URL, into report: inout Report, log: Log) {
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("recovered-\(UUID().uuidString).typ")
        defer { FileTools.removeIfPresent(scratch) }
        guard ImgContainer.extractTYP(from: img, to: scratch),
              let binary = try? TypBinary.read(scratch) else {
            log.append("the map carries no TYP — there is no look to recover")
            return
        }
        let theirs = TypSource.parse(TypDecompiler.source(binary))
        guard let rules = RuleSetIndex.read(styleDirectory: StyleCatalog.baseStyleDirectory)
        else {
            log.warn("kmap's own rules are not materialized yet — build once, then recover")
            return
        }
        // The zooms each code was seen at, so a ladder of theirs lands on ours.
        var zooms: [String: [Int: Int]] = [:]
        for (key, outcome) in report.outcomes { zooms[key] = outcome.resolutions }
        let ported = StylePort.map(codesByTag: report.codesByTag, rules: rules,
                                   theirZooms: zooms, theirTyp: theirs)
        report.style = StylePort.typ(from: theirs, ported: ported,
                                     familyID: theirs.familyID,
                                     productID: theirs.productID, codePage: theirs.codePage)
        report.ported = Dictionary(grouping: ported, by: \.kind).mapValues(\.count)
        report.uncovered = StylePort.uncovered(codesByTag: report.codesByTag, rules: rules,
                                               theirs: theirs, ported: ported)
        let counted = report.ported.map { "\($0.value) \($0.key.plural)" }.sorted()
        log.append("recovered " + counted.joined(separator: ", ") + " onto kmap's numbers")
    }

    /// The match, spread over the machine's cores: elements are independent, so the list
    /// is cut into equal spans, each core tallies its own evidence, and the tallies are
    /// folded together.
    private static func matched(_ dump: ElementDumper.Dump, against index: GroundIndex,
                                matches: UnsafeMutableBufferPointer<UInt8>,
                                progress: RecoverProgress?) async throws -> Evidence {
        let cores = max(1, min(ProcessInfo.processInfo.activeProcessorCount, 16))
        let span = (dump.count + cores - 1) / cores
        guard span > 0 else { return Evidence() }
        var out = Evidence()
        try await withThrowingTaskGroup(of: Evidence.self) { group in
            for core in 0..<cores {
                let from = core * span
                let upTo = min(dump.count, from + span)
                guard from < upTo else { continue }
                group.addTask {
                    var mine = Evidence()
                    for at in from..<upTo {
                        if at % 4096 == 0 {
                            try Task.checkCancellation()
                            progress?.advance(4096)
                        }
                        // The best any extract managed: a match stands whatever a
                        // later extract says, an ambiguity outranks a plain miss.
                        let outcome = mine.record(dump.elements[at], chain: dump.chain(at),
                                                  in: index,
                                                  resolution: dump.resolution(at))
                        if outcome.rawValue > matches[at] { matches[at] = outcome.rawValue }
                    }
                    return mine
                }
            }
            for try await part in group { out.merge(part) }
        }
        return out
    }

    enum Trouble: Error, CustomStringConvertible, LocalizedError {
        case noTiles
        case noExtracts(BBox)
        case noSuchExtract(URL)
        var description: String {
            switch self {
            case .noTiles:
                return "no map tiles found — is this a Garmin .img?"
            case .noSuchExtract(let url):
                return "no such extract: \(Paths.display(url))"
            case .noExtracts(let frame):
                return "no cached extract covers \(frame.display) — download the region"
                     + " first, or pass --extract"
            }
        }
    }
}
