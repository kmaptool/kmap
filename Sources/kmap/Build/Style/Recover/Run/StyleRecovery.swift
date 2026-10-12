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

    /// Below this share of the map's data the extracts are too little of the map to tell
    /// its style: rules it was never seen using would be judged on a few stray elements.
    /// A count of elements is no measure: a small region of a large map holds plenty.
    static let leastShare = 0.25

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

        let (grounds, wholeFrame) = try grounds(of: extracts, frame: frame, named: !explicit.isEmpty, log: log)
        // Where the map's data lies, not the ground its tiles span: a map of 2 distant
        // regions has tiles stretched over the land between them.
        let share =
            wholeFrame
            ? 1
            : ImgElements.dataShare(of: img, within: grounds)
                ?? RegionSuggestion.share(of: drawn, within: grounds)
        // Before the map is read: a refusal costs seconds, not minutes of a large map.
        if share < leastShare { throw Trouble.tooLittleGround(share: share) }

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
        let evidence = try await evidence(
            of: dump,
            coarse: coarse,
            against: extracts,
            frame: frame,
            matches: matches,
            report: &report,
            log: log,
            progress: progress
        )
        ledger(evidence, into: &report)
        let typDefined = typDefined(in: img)

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
}
