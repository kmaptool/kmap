import Foundation

extension StyleRecovery {
    /// Matches the map's elements against the OSM ground extract by extract: exact
    /// matches first, then the place for what geometry could not name.
    final class Matcher {
        let dump: ElementDumper.Dump
        /// The zoomed-out drawings: a reserve's hatch may exist only there.
        let coarse: ElementDumper.Dump
        let frame: BBox
        let log: Log
        let progress: RecoverProgress?
        /// Extracts overlap where one lies inside another, so with several an object is
        /// counted once.
        let several: Bool
        /// 1 byte per element, shared by every extract: the best match any of them
        /// managed. A raw buffer, not an array: cores write disjoint index ranges at once.
        private let matches: UnsafeMutableBufferPointer<UInt8>
        /// The coarse elements an earlier extract already witnessed, 1 per element.
        private let coarseAnswered: UnsafeMutableBufferPointer<Bool>
        private var evidence = Evidence()
        /// Guesses by place, kept until every extract has had its exact say.
        private var rescues: [CoarseEvidence.Rescue] = []
        private var rescued: Set<Int> = []
        private var countedWays = Set<Int64>()
        private var countedNodes = Set<Int64>()
        /// How many things carrying each meaning the ground holds.
        private(set) var groundTags: [String: Int] = [:]

        init(
            dump: ElementDumper.Dump,
            coarse: ElementDumper.Dump,
            frame: BBox,
            several: Bool,
            log: Log,
            progress: RecoverProgress?
        ) {
            self.dump = dump
            self.coarse = coarse
            self.frame = frame
            self.several = several
            self.log = log
            self.progress = progress
            matches = UnsafeMutableBufferPointer<UInt8>.allocate(capacity: dump.count)
            matches.initialize(repeating: Evidence.Match.unmatched.rawValue)
            coarseAnswered = UnsafeMutableBufferPointer<Bool>.allocate(capacity: coarse.count)
            coarseAnswered.initialize(repeating: false)
        }

        deinit {
            matches.deallocate()
            coarseAnswered.deallocate()
        }

        /// 1 extract's say on every element.
        func read(_ extract: URL) async throws {
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
            // The meanings over every core; the counting in order, as an object already
            // counted in an earlier extract is not counted again.
            let wayMeanings = Lanes.map(index.ways.count) { DefaultRuleBook.meaning(of: index.ways[$0].tags) }
            for (at, way) in index.ways.enumerated() where !several || countedWays.insert(way.id).inserted {
                if let tag = wayMeanings[at] { groundTags[tag, default: 0] += 1 }
            }
            let nodeMeanings = Lanes.map(index.nodes.count) { DefaultRuleBook.meaning(of: index.nodes[$0].tags) }
            for (at, node) in index.nodes.enumerated() where !several || countedNodes.insert(node.id).inserted {
                if let tag = nodeMeanings[at] { groundTags[tag, default: 0] += 1 }
            }
            progress?.move(to: .matching(extract.lastPathComponent))
            progress?.count(0, of: dump.count)
            evidence.merge(
                try await Self.matched(
                    dump,
                    against: index,
                    matches: matches,
                    progress: progress
                )
            )
            // What geometry could not name is asked of the place. Its own stage, or
            // the bar sits on a finished 100% while this works.
            progress?.move(to: .placing(extract.lastPathComponent))
            await CoarseEvidence.match(coarse, index: index, answered: coarseAnswered, into: &evidence)
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

        /// The evidence of every extract read, the guesses by place settled.
        func finish() -> Evidence {
            CoarseEvidence.settle(rescues, matches: matches, into: &evidence)
            evidence.tally(dump, matches: UnsafeBufferPointer(matches))
            return evidence
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
            let cores = max(1, min(ProcessInfo.processInfo.activeProcessorCount, StyleRecovery.mostCores))
            let span = (dump.count + cores - 1) / cores
            guard span > 0 else { return Evidence() }
            // Each core's part goes to its own place, not back through the group: see
            // `ExtractLocator.newestAnswering`. Merged in core order, so a sum over parts
            // comes out the same every run.
            let parts = Locked([Evidence?](repeating: nil, count: cores))
            // Each core writes only the matches of its own span: nothing is shared.
            nonisolated(unsafe) let matches = matches
            try await withThrowingTaskGroup(of: Void.self) { group in
                for core in 0..<cores {
                    let from = core * span
                    let upTo = min(dump.count, from + span)
                    guard from < upTo else { continue }
                    group.addTask {
                        var mine = Evidence()
                        for at in from..<upTo {
                            if at % StyleRecovery.progressStride == 0 {
                                try Task.checkCancellation()
                                progress?.advance(StyleRecovery.progressStride)
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
                        let part = mine
                        parts.withLock { $0[core] = part }
                    }
                }
                try await group.waitForAll()
            }
            var out = Evidence()
            for part in parts.withLock({ $0 }) { if let part { out.merge(part) } }
            return out
        }
    }
}
