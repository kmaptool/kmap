import Foundation

extension StyleRecovery {
    /// Every extract's say on every element: exact matches first, then the place for
    /// what geometry could not name. Counts the ground's meanings into the report.
    static func evidence(
        of dump: ElementDumper.Dump,
        coarse: ElementDumper.Dump,
        against extracts: [URL],
        frame: BBox,
        matches: UnsafeMutableBufferPointer<UInt8>,
        report: inout Report,
        log: Log,
        progress: RecoverProgress?
    ) async throws -> Evidence {
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
        return evidence
    }

    /// The match, spread over the machine's cores: elements are independent, so the list
    /// is cut into equal spans, each core tallies its own evidence, and the tallies are
    /// folded together.
    static func matched(
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
}
