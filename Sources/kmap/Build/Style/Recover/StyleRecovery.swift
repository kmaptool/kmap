import Foundation

/// Recovers a foreign map's code vocabulary as a reassignment sheet.
///
/// A compiled map keeps only codes, geometry and labels, on the 2.4 m Garmin grid. An
/// element's vertex chain names the OSM way it was compiled from, whose tags give the
/// rule line that should emit the foreign code. The output is a substitution sheet,
/// applied per style at build time.
enum StyleRecovery {
    /// Codes kmap manufactures rather than reads: contours from the DEM, sea and the
    /// background under it. No OSM way is their source, so no evidence can exist.
    ///
    /// The land polygon is deliberately NOT here. It rides on 0x27, and a borrowed
    /// style that paints that number paints it over every acre of the map - the one
    /// tried it as a construction hatch, and the whole country came out a building
    /// site. Land is drawn only where their vocabulary leaves the number alone, which
    /// is the same rule everything else follows.
    static let generated: Set<String> = ["L20", "L21", "L22", "A32", "A4A", "A4B"]

    /// The most cores the matching is spread over, and how many elements go by
    /// between two looks at the progress and the cancellation.
    static let mostCores = 16
    static let progressStride = 4096

    /// Below this share of the map's data, and below `fewestElements` read over it, the
    /// extracts are too little of the map to tell its style: rules it was never seen
    /// using would be judged on a few stray elements.
    static let leastShare = 0.25
    static let fewestElements = 50_000

    /// What can be refused before any reading: no map, no tiles in it, an extract named
    /// that is not there or whose header puts it beside the map. Returns the map's ground.
    @discardableResult
    static func checkInputs(img: URL, extracts: [URL]) throws -> RegionSuggestion.DrawnGround {
        guard FileTools.exists(img) else { throw Trouble.noSuchMap(img) }
        let drawn = RegionSuggestion.drawnGround(of: img)
        guard drawn.frame.isValid else { throw Trouble.noTiles }
        for extract in extracts {
            guard FileTools.exists(extract) else { throw Trouble.noSuchExtract(extract) }
            if let box = (try? PBFReader(url: extract).headerBBox()) ?? nil {
                let bbox = BBox(minLon: box.minLon, minLat: box.minLat, maxLon: box.maxLon, maxLat: box.maxLat)
                if !bbox.intersection(drawn.frame).isValid {
                    throw Trouble.extractMissesMap(extract, drawn.frame)
                }
            }
        }
        return drawn
    }

    /// The whole pipeline: dump, index, match, aggregate, derive.
    ///
    /// Cancellation is the task's: it kills the reader process, and the matching loop
    /// checks between elements.
    static func run(
        img: URL,
        extracts explicit: [URL],
        log: Log,
        rulesDirectory: URL? = nil,
        progress: RecoverProgress? = nil
    ) async throws -> Report {
        var report = Report()
        let drawn = try checkInputs(img: img, extracts: explicit)
        let frame = drawn.frame
        report.frame = frame

        // Ground truth: the extracts handed in, or every cached extract touching a tile.
        // Tiles rather than the frame: the frame spans ground a non-rectangular map
        // never draws.
        let extracts =
            explicit.isEmpty
            ? RegionSuggestion.cachedExtracts(drawnOn: drawn) : explicit
        guard !extracts.isEmpty else { throw Trouble.noExtracts(frame) }
        report.extracts = extracts

        // One ground per extract, clipped to the frame: identification can happen only
        // where an extract covers the map, and one box around distant extracts would
        // read the gap between them too.
        // A header that carries no box is measured from the file's own nodes instead: the
        // extract is matched against below all the same, so its ground has to be read, and
        // one pass over one file beats reading the whole frame in its place.
        var grounds: [BBox] = []
        var wholeFrame = false
        for extract in extracts {
            let reader = PBFReader(url: extract)
            var box = ((try? reader.headerBBox()) ?? nil).map {
                BBox(
                    minLon: $0.minLon,
                    minLat: $0.minLat,
                    maxLon: $0.maxLon,
                    maxLat: $0.maxLat
                )
            }
            if box == nil {
                log.step(
                    "\(extract.lastPathComponent) carries no bounding box in its"
                        + " header — reading its nodes for one"
                )
                do {
                    // No nodes at all: the extract covers no ground, and nothing it holds
                    // can name anything on the map.
                    guard let measured = try reader.nodeBounds() else { continue }
                    box = measured
                    log.append("its own nodes lie in \(measured.display)")
                } catch {
                    log.warn(
                        "\(extract.lastPathComponent) cannot be read for its bounds,"
                            + " so the whole frame is searched — this takes longer"
                    )
                    grounds = [frame]
                    wholeFrame = true
                    break
                }
            }
            guard let within = box?.intersection(frame), within.isValid else {
                // Named by hand, an extract beside the map is a mistake worth saying.
                if !explicit.isEmpty { throw Trouble.extractMissesMap(extract, frame) }
                continue
            }
            grounds.append(within)
        }
        // Where the map's data lies, not the ground its tiles span: a map of 2 distant
        // regions has tiles stretched over the land between them.
        let share =
            wholeFrame
            ? 1
            : ImgElements.dataShare(of: img, within: grounds)
                ?? RegionSuggestion.share(of: drawn, within: grounds)

        log.step("reading the map's elements")
        progress?.move(to: .reading)
        let dump = try ElementDumper.dump(
            img: img,
            grounds: grounds,
            log: log,
            progress: progress
        )
        report.elements = dump.count
        log.append("\(dump.count) element(s) at the detail level, over the ground searched")
        if share < leastShare && dump.count < fewestElements {
            throw Trouble.tooLittleGround(share: share, elements: dump.count)
        }
        if let finest = dump.resolutions.max(), finest < GarminGrid.fullResolution {
            log.warn(
                "the detail level is drawn at resolution \(finest), not"
                    + " \(GarminGrid.fullResolution): its vertices are rounded off the grid,"
                    + " and few will match"
            )
        }

        // One byte per element, shared by every extract: the best match any of them
        // managed. A raw buffer, not an array: cores write disjoint index ranges at once.
        let matches = UnsafeMutableBufferPointer<UInt8>.allocate(capacity: dump.count)
        matches.initialize(repeating: Evidence.Match.unmatched.rawValue)
        defer { matches.deallocate() }

        // The zoomed-out drawings too: a reserve's hatch may exist only there.
        let coarse =
            (try? ElementDumper.dump(
                img: img,
                grounds: grounds,
                log: log,
                coarserLevels: true
            )) ?? ElementDumper.Dump()
        var coarseAnswered = [Bool](repeating: false, count: coarse.count)

        var evidence = Evidence()
        // Guesses by place, kept until every extract has had its exact say.
        var rescues: [CoarseEvidence.Rescue] = []
        var rescued: Set<Int> = []
        // Extracts overlap where one lies inside another; an object is counted once.
        var countedWays = Set<Int64>(), countedNodes = Set<Int64>()
        for extract in extracts {
            try Task.checkCancellation()
            log.step("matching against \(extract.lastPathComponent)")
            progress?.move(to: .indexing(extract.lastPathComponent))
            let index: GroundIndex
            do {
                index = try GroundIndex(extract: extract, frame: frame)
            } catch let error as PBFError {
                // Several extracts may be read: the one that failed is named.
                throw Trouble.unreadableExtract(extract, error)
            }
            log.append("\(index.ways.count) tagged way(s), \(index.nodes.count) tagged node(s) in frame")
            let several = extracts.count > 1
            for way in index.ways where !several || countedWays.insert(way.id).inserted {
                if let tag = DefaultRuleBook.meaning(of: way.tags) {
                    report.groundTags[tag, default: 0] += 1
                }
            }
            for node in index.nodes where !several || countedNodes.insert(node.id).inserted {
                if let tag = DefaultRuleBook.meaning(of: node.tags) {
                    report.groundTags[tag, default: 0] += 1
                }
            }
            progress?.move(to: .matching(extract.lastPathComponent))
            progress?.count(0, of: dump.count)
            evidence.merge(
                try await matched(
                    dump,
                    against: index,
                    matches: matches,
                    progress: progress
                )
            )
            // What geometry could not name is asked of the place. Its own stage, or
            // the bar sits on a finished 100% while this works.
            progress?.move(to: .placing(extract.lastPathComponent))
            CoarseEvidence.match(coarse, index: index, answered: &coarseAnswered, into: &evidence)
            try Task.checkCancellation()
            // A point an earlier extract named by place is not looked up again: the first
            // guess is the one `settle` keeps.
            let found = await CoarseEvidence.rescuePoints(
                dump,
                matches: matches,
                index: index,
                skipping: rescued,
                progress: progress
            )
            try Task.checkCancellation()
            rescued.formUnion(found.map(\.at))
            rescues += found
        }
        CoarseEvidence.settle(rescues, matches: matches, into: &evidence)
        evidence.tally(dump, matches: UnsafeBufferPointer(matches))

        // Per-meaning ledger: which codes this map was seen drawing each tag with.
        for (key, code) in evidence.codes {
            for (id, tags) in code.sources {
                guard let tag = DefaultRuleBook.meaning(of: tags) else { continue }
                report.codesByTag[tag, default: [:]][key, default: 0] += 1
                if let area = code.extent[id] {
                    report.areaByTag[tag, default: [:]][key, default: 0] += area
                }
            }
        }

        // The TYP the map carries, for the silencing gate: only a code their TYP
        // paints can paint the wrong thing. A map without a TYP silences nothing.
        var typDefined: [ElementDumper.Kind: Set<Int>] = [:]
        let typScratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("recover-\(UUID().uuidString).typ")
        if ImgContainer.extractTYP(from: img, to: typScratch),
            let typ = try? TypBinary.read(typScratch)
        {
            typDefined[.area] = Set(typ.polygons.map(\.code))
            typDefined[.line] = Set(typ.lines.map(\.code))
            typDefined[.point] = Set(typ.points.map(\.code))
        }
        FileTools.removeIfPresent(typScratch)

        try Task.checkCancellation()
        progress?.move(to: .deriving)
        let rules = rulesDirectory.map { DefaultRuleBook.load(from: $0) } ?? DefaultRuleBook.load()
        derive(
            evidence,
            into: &report,
            rules: rules,
            typDefined: typDefined,
            ground: report.groundTags
        )
        try Task.checkCancellation()
        recoverStyle(from: img, into: &report, log: log, rulesDirectory: rulesDirectory)
        // Asked last too: a caller writes what is returned.
        try Task.checkCancellation()
        return report
    }

    /// Their look on kmap's numbers, as a TYP source. The pictures come from the TYP
    /// the map carries; which lands on which of our numbers is the evidence's to say.
    /// Silent where there is nothing to recover, or no rules of ours to put it on.
    /// Our numbers are read from the neutral rules where given: the last build's own
    /// set carries its hides, and a hidden number would come out unpainted.
    private static func recoverStyle(
        from img: URL,
        into report: inout Report,
        log: Log,
        rulesDirectory: URL?
    ) {
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("recovered-\(UUID().uuidString).typ")
        defer { FileTools.removeIfPresent(scratch) }
        guard ImgContainer.extractTYP(from: img, to: scratch),
            let binary = try? TypBinary.read(scratch)
        else {
            log.append("the map carries no TYP — there is no look to recover")
            return
        }
        let theirs = TypSource.parse(TypDecompiler.source(binary))
        guard
            let rules = RuleSetIndex.read(
                styleDirectory: rulesDirectory ?? StyleCatalog.baseStyleDirectory
            )
        else {
            log.warn("kmap's own rules are not materialized yet — build once, then recover")
            return
        }
        // The zooms each code was seen at, so a ladder of theirs lands on ours.
        var zooms: [String: [Int: Int]] = [:]
        for (key, outcome) in report.outcomes { zooms[key] = outcome.resolutions }
        let ported = StylePort.map(
            codesByTag: report.codesByTag,
            rules: rules,
            theirZooms: zooms,
            theirTyp: theirs,
            theirAreas: report.areaByTag
        )
        report.codePage = theirs.codePage
        report.style = StylePort.typ(
            from: theirs,
            ported: ported,
            familyID: theirs.familyID,
            productID: theirs.productID,
            codePage: theirs.codePage,
            unstyled: StylePort.leftToTheDevice(
                codesByTag: report.codesByTag,
                rules: rules,
                theirTyp: theirs,
                ported: ported
            )
        )
        // Counted as the TYP has them: a port onto a ground number is drawn from the
        // ground's own section, and its picture is one no number of ours carries.
        let drawn = StylePort.drawn(ported)
        report.ported = Dictionary(grouping: drawn, by: \.kind).mapValues(\.count)
        report.contested = drawn.filter { !$0.rivals.isEmpty }
        report.uncovered = StylePort.uncovered(
            codesByTag: report.codesByTag,
            rules: rules,
            theirs: theirs,
            ported: drawn
        )
        let counted = report.ported.map { "\($0.value) \($0.key.plural)" }.sorted()
        log.append(
            counted.isEmpty
                ? "nothing recovered onto kmap's numbers"
                : "recovered " + counted.joined(separator: ", ") + " onto kmap's numbers"
        )
    }

    /// The match, spread over the machine's cores: elements are independent, so the list
    /// is cut into equal spans, each core tallies its own evidence, and the tallies are
    /// folded together.
    private static func matched(
        _ dump: ElementDumper.Dump,
        against index: GroundIndex,
        matches: UnsafeMutableBufferPointer<UInt8>,
        progress: RecoverProgress?
    ) async throws -> Evidence {
        let cores = max(1, min(ProcessInfo.processInfo.activeProcessorCount, mostCores))
        let span = (dump.count + cores - 1) / cores
        guard span > 0 else { return Evidence() }
        var out = Evidence()
        // Each core writes only the matches of its own span: nothing is shared.
        nonisolated(unsafe) let matches = matches
        try await withThrowingTaskGroup(of: Evidence.self) { group in
            for core in 0..<cores {
                let from = core * span
                let upTo = min(dump.count, from + span)
                guard from < upTo else { continue }
                group.addTask {
                    var mine = Evidence()
                    for at in from..<upTo {
                        if at % progressStride == 0 {
                            try Task.checkCancellation()
                            progress?.advance(progressStride)
                        }
                        // Matched against an earlier extract already: where extracts
                        // overlap it would be counted twice, its zooms and its area too.
                        if matches[at] == Evidence.Match.matched.rawValue { continue }
                        // The best any extract managed: a match stands whatever a
                        // later extract says, an ambiguity outranks a plain miss.
                        let outcome = mine.record(
                            dump.elements[at],
                            chain: dump.chain(at),
                            in: index,
                            resolution: dump.resolution(at)
                        )
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
        case noSuchMap(URL)
        case unreadableExtract(URL, PBFError)
        case noExtracts(BBox)
        case noSuchExtract(URL)
        case extractMissesMap(URL, BBox)
        case tooLittleGround(share: Double, elements: Int)

        var isTooLittleGround: Bool {
            if case .tooLittleGround = self { return true }
            return false
        }

        var description: String {
            switch self {
            case .extractMissesMap(let url, let frame):
                return "\(url.lastPathComponent) does not reach the map, which lies in \(frame.display)"
                    + " — pass the extract of the region the map shows"
            case .tooLittleGround(let share, let elements):
                return "the extracts hold \(Int((share * 100).rounded()))% of the map's data,"
                    + " \(elements) element(s): too little to tell its style"
                    + " — pass the extract of the region the map shows"
            case .noTiles:
                return "no map tiles found — is this a Garmin .img?"
            case .unreadableExtract(let url, let error):
                return "\(url.lastPathComponent): \(error)"
            case .noSuchMap(let url):
                return "no such map: \(Paths.display(url))"
            case .noSuchExtract(let url):
                return "no such extract: \(Paths.display(url))"
            case .noExtracts(let frame):
                return "no cached extract covers \(frame.display) — download the region"
                    + " first, or pass --extract"
            }
        }
    }
}
