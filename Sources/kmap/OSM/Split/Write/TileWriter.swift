import Foundation

extension TileSplitter {
    /// One tile being written: batches of a few thousand objects, flushed as they fill.
    final class TileWriter {
        let url: URL
        let area: Area
        private let writer: PBFWriter
        /// The first write that failed, as soon as the writer's queue saw it.
        var failure: Error? { writer.writeFailure }
        private var nodes: [PBFWriter.Node] = []
        private var ways: [PBFWriter.Way] = []
        private var relations: [PBFWriter.Relation] = []
        /// Runs of a batch still filling, and how many elements they come to. A build
        /// hands over either single elements or runs, never both.
        private var nodeRuns: [(chunk: PBFWriter.NodeChunk, range: Range<Int>)] = []
        private var nodesInRuns = 0
        private var wayRuns: [(chunk: PBFWriter.WayChunk, range: Range<Int>)] = []
        private var waysInRuns = 0
        /// Whether the last run of the batch is the writer's own, which small runs are
        /// copied into.
        private var gatheringNodes = false
        private var gatheringWays = false
        private(set) var nodeCount = 0

        init(url: URL, area: Area) throws {
            self.url = url
            self.area = area
            writer = try PBFWriter(to: url)
            writer.header(
                bbox: (
                    minLat: TileSplitter.degrees(area.minLat),
                    minLon: TileSplitter.degrees(area.minLon),
                    maxLat: TileSplitter.degrees(area.maxLat),
                    maxLon: TileSplitter.degrees(area.maxLon)
                )
            )
        }

        private static let nodesPerBatch = 16000
        private static let waysPerBatch = 4000
        /// Below this a run is copied into the writer's own: a run is several arrays, and a
        /// tile can be handed thousands of runs of a node or 2 before its batch fills.
        static let smallRun = 64

        func add(_ node: PBFWriter.Node) {
            assert(nodeRuns.isEmpty, "a build hands over single nodes or runs, never both")
            nodes.append(node)
            nodeCount += 1
            if nodes.count >= Self.nodesPerBatch { writer.nodes(nodes); nodes.removeAll(keepingCapacity: true) }
        }

        /// The same as adding each in turn, batches cut at the same places; the run is
        /// kept as it is, a batch holding the stretch of it that is its own.
        func add(nodes run: PBFWriter.NodeChunk) {
            assert(nodes.isEmpty, "a build hands over single nodes or runs, never both")
            nodeCount += run.count
            if run.count < Self.smallRun {
                gather(nodes: run)
                return
            }
            gatheringNodes = false
            var at = 0
            while at < run.count {
                let take = min(run.count - at, Self.nodesPerBatch - nodesInRuns)
                nodeRuns.append((run, at..<(at + take)))
                nodesInRuns += take
                at += take
                if nodesInRuns >= Self.nodesPerBatch { flushNodeRuns() }
            }
        }

        /// Copies a small run into the writer's own run, the batch cut where it would be.
        /// Its strings are numbered afresh in the run they land in, in the order first met:
        /// what is written is the same as for the run handed over whole. The run is taken out
        /// of the list while it fills, so it is filled in place.
        private func gather(nodes run: PBFWriter.NodeChunk) {
            var at = 0
            while at < run.count {
                if !gatheringNodes {
                    nodeRuns.append((PBFWriter.NodeChunk(), 0..<0))
                    gatheringNodes = true
                }
                let last = nodeRuns.count - 1
                var chunk = nodeRuns[last].chunk
                nodeRuns[last].chunk = PBFWriter.NodeChunk()
                let take = min(run.count - at, Self.nodesPerBatch - nodesInRuns)
                renumbering(run.strings.count)
                for element in at..<(at + take) {
                    chunk.ids.append(run.ids[element])
                    chunk.lats.append(run.lats[element])
                    chunk.lons.append(run.lons[element])
                    for tag in (element == 0 ? 0 : Int(run.tagEnds[element - 1]))..<Int(run.tagEnds[element]) {
                        chunk.tags.append(renumbered(Int(run.tags[tag]), from: run.strings, into: &chunk.strings))
                    }
                    chunk.tagEnds.append(Int32(chunk.tags.count))
                }
                nodeRuns[last] = (chunk, 0..<chunk.count)
                nodesInRuns += take
                at += take
                if nodesInRuns >= Self.nodesPerBatch { flushNodeRuns() }
            }
        }

        private func gather(ways run: PBFWriter.WayChunk) {
            var at = 0
            while at < run.count {
                if !gatheringWays {
                    wayRuns.append((PBFWriter.WayChunk(), 0..<0))
                    gatheringWays = true
                }
                let last = wayRuns.count - 1
                var chunk = wayRuns[last].chunk
                wayRuns[last].chunk = PBFWriter.WayChunk()
                let take = min(run.count - at, Self.waysPerBatch - waysInRuns)
                renumbering(run.strings.count)
                for element in at..<(at + take) {
                    chunk.ids.append(run.ids[element])
                    chunk.refs.append(
                        contentsOf: run.refs[
                            (element == 0 ? 0 : Int(run.refEnds[element - 1]))..<Int(run.refEnds[element])
                        ]
                    )
                    chunk.refEnds.append(Int32(chunk.refs.count))
                    for tag in (element == 0 ? 0 : Int(run.tagEnds[element - 1]))..<Int(run.tagEnds[element]) {
                        chunk.tags.append(renumbered(Int(run.tags[tag]), from: run.strings, into: &chunk.strings))
                    }
                    chunk.tagEnds.append(Int32(chunk.tags.count))
                }
                wayRuns[last] = (chunk, 0..<chunk.count)
                waysInRuns += take
                at += take
                if waysInRuns >= Self.waysPerBatch { flushWayRuns() }
            }
        }

        /// A run's strings by its own number, as numbered in the run they are copied into:
        /// kept between runs, cleared for each.
        private var renumber: [Int32] = []

        private func renumbering(_ count: Int) {
            renumber.removeAll(keepingCapacity: true)
            renumber.append(contentsOf: repeatElement(-1, count: count))
        }

        private func renumbered(_ source: Int, from strings: [String], into target: inout [String]) -> Int32 {
            if renumber[source] < 0 {
                renumber[source] = Int32(target.count)
                target.append(strings[source])
            }
            return renumber[source]
        }

        private func flushNodeRuns() {
            gatheringNodes = false
            guard nodesInRuns > 0 else { return }
            writer.nodes(runs: nodeRuns)
            nodeRuns.removeAll(keepingCapacity: true)
            nodesInRuns = 0
        }

        private func flushWayRuns() {
            gatheringWays = false
            guard waysInRuns > 0 else { return }
            writer.ways(runs: wayRuns)
            wayRuns.removeAll(keepingCapacity: true)
            waysInRuns = 0
        }

        func add(_ way: PBFWriter.Way) {
            assert(wayRuns.isEmpty, "a build hands over single ways or runs, never both")
            flushNodes()
            ways.append(way)
            if ways.count >= Self.waysPerBatch { writer.ways(ways); ways.removeAll(keepingCapacity: true) }
        }

        /// The same as adding each in turn, batches cut at the same places.
        func add(ways run: PBFWriter.WayChunk) {
            guard run.count > 0 else { return }
            assert(ways.isEmpty, "a build hands over single ways or runs, never both")
            flushNodes()
            if run.count < Self.smallRun {
                gather(ways: run)
                return
            }
            gatheringWays = false
            var at = 0
            while at < run.count {
                let take = min(run.count - at, Self.waysPerBatch - waysInRuns)
                wayRuns.append((run, at..<(at + take)))
                waysInRuns += take
                at += take
                if waysInRuns >= Self.waysPerBatch { flushWayRuns() }
            }
        }

        func add(_ relation: PBFWriter.Relation) {
            flushNodes()
            flushWayRuns()
            if !ways.isEmpty { writer.ways(ways); ways.removeAll(keepingCapacity: true) }
            relations.append(relation)
            if relations.count >= 4000 {
                writer.relations(relations)
                relations.removeAll(keepingCapacity: true)
            }
        }

        private func flushNodes() {
            flushNodeRuns()
            if !nodes.isEmpty { writer.nodes(nodes); nodes.removeAll(keepingCapacity: true) }
        }

        func finish() throws {
            flushNodes()
            flushWayRuns()
            if !ways.isEmpty { writer.ways(ways) }
            if !relations.isEmpty { writer.relations(relations) }
            try writer.finish()
        }
    }
}
