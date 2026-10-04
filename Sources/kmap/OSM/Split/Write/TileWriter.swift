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

        func add(_ node: PBFWriter.Node) {
            nodes.append(node)
            nodeCount += 1
            if nodes.count >= Self.nodesPerBatch { writer.nodes(nodes); nodes.removeAll(keepingCapacity: true) }
        }

        /// The same as adding each in turn, batches cut at the same places; the run is
        /// kept as it is, a batch holding the stretch of it that is its own.
        func add(nodes run: PBFWriter.NodeChunk) {
            nodeCount += run.count
            var at = 0
            while at < run.count {
                let take = min(run.count - at, Self.nodesPerBatch - nodesInRuns)
                nodeRuns.append((run, at..<(at + take)))
                nodesInRuns += take
                at += take
                if nodesInRuns >= Self.nodesPerBatch { flushNodeRuns() }
            }
        }

        private func flushNodeRuns() {
            guard nodesInRuns > 0 else { return }
            writer.nodes(runs: nodeRuns)
            nodeRuns.removeAll(keepingCapacity: true)
            nodesInRuns = 0
        }

        private func flushWayRuns() {
            guard waysInRuns > 0 else { return }
            writer.ways(runs: wayRuns)
            wayRuns.removeAll(keepingCapacity: true)
            waysInRuns = 0
        }

        func add(_ way: PBFWriter.Way) {
            flushNodes()
            ways.append(way)
            if ways.count >= Self.waysPerBatch { writer.ways(ways); ways.removeAll(keepingCapacity: true) }
        }

        /// The same as adding each in turn, batches cut at the same places.
        func add(ways run: PBFWriter.WayChunk) {
            guard run.count > 0 else { return }
            flushNodes()
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
