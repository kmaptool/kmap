import Foundation

/// Writes a repaired copy of a PBF. A block holding something this pass changes is
/// decoded, altered and written again; every other block is copied over as the compressed
/// bytes it already is.
struct PBFRewriter {
    enum Trouble: Error, CustomStringConvertible, LocalizedError {
        case mixedBlock

        var description: String {
            "a block holds relations as well as the ways being repaired, which this writer"
                + " does not rebuild -- report the extract, it is not the usual layout"
        }
    }

    /// The tags this pass writes, for the style rules to match on.
    static let barrierTag = "kmap:on"
    static let duplicateVenueTag = "kmap:dup_venue"
    static let repairTag = "kmap:repair"

    let url: URL
    let plan: RepairPlan
    let network: RoadNetwork
    let language: String
    /// Barrier node to the class of way it stands on; a node does not itself record which
    /// way contains it.
    var barriers: [Int64: String] = [:]
    /// Whether to drop a description that only repeats the name beside it.
    var tidyDescriptions = false
    /// Areas repeating a venue already on the map, tagged so the style can hide the
    /// second icon.
    var duplicateVenues: Set<Int64> = []
    /// Contour files to fold into this one, in id order. splitter keeps ways complete only
    /// for its first input file, so contours handed to it separately are cut at every tile
    /// boundary they cross.
    var contours: [URL] = []

    /// Blocks copied, blocks rebuilt, and objects added.
    struct Tally {
        var copied = 0
        var rebuilt = 0
        var addedNodes = 0
        var addedWays = 0
        var tagged = 0
        var dropped = 0
        var marked = 0
        var contourBlocks = 0
    }

    /// What each contour file's data blobs hold, recorded on the first walk: bit 0 nodes,
    /// bit 1 ways. The files are walked twice, nodes before ways.
    var contourKinds: [[UInt8]] = []

    mutating func write(to destination: URL) throws -> Tally {
        // A cheap rejection test in front of the tables. Nodes and ways are filtered
        // separately: a node id and a way id may be the same number.
        let nodeFilter = IDFilter(Array(plan.moves.keys) + Array(barriers.keys))
        let wayFilter = IDFilter(
            Array(plan.inserts.keys.map { network.wayID[Int($0)] })
                + Array(duplicateVenues)
        )
        let mergeFilter = IDFilter(Array(plan.merges.keys))
        let moveFilter = IDFilter(Array(plan.moves.keys))
        let moved: [Int64: (lat: Double, lon: Double)] = plan.moves
        var inserts: [Int64: [(after: Int64, segment: Int32, along: Double, node: Int64)]] = [:]
        for (way, list) in plan.inserts {
            // Furthest along a segment first: each goes in right after the segment's
            // start, so the way keeps its direction.
            inserts[network.wayID[Int(way)]] = list.sorted {
                ($0.after, $0.along) > ($1.after, $1.along)
            }
        }

        let writer = try PBFWriter(to: destination)
        var tally = Tally()
        var addedNodes = false
        var addedWays = false

        let data = try Data(contentsOf: url, options: .alwaysMapped)
        var scratch = [UInt8](repeating: 0, count: PBFSchema.maxUncompressedBlob)

        // Blocks are inflated and decoded a batch at a time across every core, then acted
        // on in file order: objects this pass adds go into the first block of their kind.
        let width = Machine.readers
        var scratches = [[UInt8]](repeating: [], count: width)
        // One set of decode buffers per slot, kept for the whole file.
        var fieldSets = (0..<width).map { _ in PBFReader.Scratch() }
        var decoded = [Block?](repeating: nil, count: width)
        var prepared = [Rebuilt?](repeating: nil, count: width)
        var failures = [Error?](repeating: nil, count: width)
        var batch:
            [(
                header: UnsafeRawBufferPointer, blob: UnsafeRawBufferPointer,
                isData: Bool
            )] = []
        batch.reserveCapacity(width)

        try data.withUnsafeBytes { file in
            func decodeBatch() throws {
                guard !batch.isEmpty else { return }
                let items = batch
                try scratches.withUnsafeMutableBufferPointer { buffers in
                    try fieldSets.withUnsafeMutableBufferPointer { fields in
                        try decoded.withUnsafeMutableBufferPointer { blocks in
                            try PBFReader.acrossCores(items.count, failures: &failures) { i in
                                blocks[i] = nil
                                guard items[i].isData else { return }
                                let size = try PBFReader.inflate(
                                    items[i].blob,
                                    into: &buffers[i]
                                )
                                blocks[i] = try buffers[i].withUnsafeBytes {
                                    try Block(
                                        UnsafeRawBufferPointer(rebasing: $0[0..<size]),
                                        fields: &fields[i]
                                    )
                                }
                            }
                        }
                    }
                }
                // Whether a block needs rebuilding, and the rebuilding, depend on nothing
                // but the block and the tables, so they run on every core.
                try prepared.withUnsafeMutableBufferPointer { slots in
                    try PBFReader.acrossCores(items.count, failures: &failures) { i in
                        slots[i] = nil
                        guard let block = decoded[i] else { return }
                        slots[i] = try rebuild(
                            block,
                            moved: moved,
                            inserts: inserts,
                            nodeFilter: nodeFilter,
                            wayFilter: wayFilter,
                            mergeFilter: mergeFilter,
                            moveFilter: moveFilter
                        )
                    }
                }
                for i in 0..<items.count {
                    guard let block = decoded[i] else {
                        // Not an OSMData blob: the file header, straight through.
                        writer.copy(header: items[i].header, blob: items[i].blob)
                        tally.copied += 1
                        continue
                    }
                    try write(
                        prepared[i],
                        of: block,
                        header: items[i].header,
                        blob: items[i].blob,
                        writer: writer,
                        tally: &tally,
                        scratch: &scratch,
                        addedNodes: &addedNodes,
                        addedWays: &addedWays
                    )
                }
                batch.removeAll(keepingCapacity: true)
            }

            try PBFReader.forEachBlob(in: file) { header, kind, blob in
                batch.append((header, blob, kind == PBFSchema.dataBlob))
                if batch.count == width { try decodeBatch() }
            }
            try decodeBatch()
        }

        if !addedNodes {
            tally.contourBlocks += try copyContours(.nodes, into: writer, scratch: &scratch)
            let batch = inventedNodes()
            writer.nodes(batch)
            tally.addedNodes = batch.count
        }
        if !addedWays {
            tally.contourBlocks += try copyContours(.ways, into: writer, scratch: &scratch)
            let batch = inventedWays()
            writer.ways(batch)
            tally.addedWays = batch.count
        }
        try writer.finish()
        return tally
    }

    /// A block prepared but not yet written. Touches neither the writer nor any running
    /// total, so it can be built on any thread.
    private struct Rebuilt {
        /// Nil when the block needs nothing and its bytes go through as they are.
        var nodes: [PBFWriter.Node]?
        var ways: [PBFWriter.Way]?
        var tagged = 0
        var dropped = 0
        var marked = 0
        var touched: Bool { nodes != nil || ways != nil }
    }

    /// Returns the block with repairs, barrier tags and tidied descriptions applied, or an
    /// untouched result if it needs none.
    /// - Throws: `Trouble.mixedBlock` when the block holds relations as well as ways.
    private func rebuild(
        _ block: Block,
        moved: [Int64: (lat: Double, lon: Double)],
        inserts: [Int64: [(after: Int64, segment: Int32, along: Double, node: Int64)]],
        nodeFilter: IDFilter,
        wayFilter: IDFilter,
        mergeFilter: IDFilter,
        moveFilter: IDFilter
    ) throws -> Rebuilt {
        var out = Rebuilt()
        let touched =
            block.nodeIDs.contains {
                nodeFilter.mayContain($0) && (moved[$0] != nil || barriers[$0] != nil)
            }
            || block.wayIDs.contains {
                wayFilter.mayContain($0)
                    && (inserts[$0] != nil || duplicateVenues.contains($0))
            }
            || block.usesAny(of: plan.merges, filter: mergeFilter)
            || (tidyDescriptions && block.hasRedundantDescription)
        guard touched else { return out }
        if block.hasRelations && (block.hasWays || block.hasNodes) { throw Trouble.mixedBlock }

        // A block may hold both nodes and ways.
        if block.hasNodes {
            var batch = block.nodes(movedBy: moved, filter: moveFilter)
            for i in batch.indices {
                if let kind = barriers[batch[i].id] {
                    batch[i].tags.append((Self.barrierTag, kind))
                    out.tagged += 1
                }
                if tidyDescriptions { out.dropped += Self.tidy(&batch[i].tags) }
            }
            out.nodes = batch
        }
        if block.hasWays {
            var batch = block.ways(inserting: inserts, merging: plan.merges)
            for i in batch.indices {
                if tidyDescriptions { out.dropped += Self.tidy(&batch[i].tags) }
                if duplicateVenues.contains(batch[i].id) {
                    batch[i].tags.append((Self.duplicateVenueTag, "yes"))
                    out.marked += 1
                }
            }
            out.ways = batch
        }
        return out
    }

    /// Writes one prepared block. Runs in file order: it inserts this pass's own objects
    /// and updates the running totals.
    private mutating func write(
        _ ready: Rebuilt?,
        of block: Block,
        header: UnsafeRawBufferPointer,
        blob: UnsafeRawBufferPointer,
        writer: PBFWriter,
        tally: inout Tally,
        scratch: inout [UInt8],
        addedNodes: inout Bool,
        addedWays: inout Bool
    ) throws {
        // A PBF is ordered nodes, ways, relations: new nodes go in before the first way,
        // new ways before the first relation.
        if block.hasWays && !addedNodes {
            addedNodes = true
            tally.contourBlocks += try copyContours(.nodes, into: writer, scratch: &scratch)
            let batch = inventedNodes()
            writer.nodes(batch)
            tally.addedNodes = batch.count
        }
        if block.hasRelations && !addedWays {
            addedWays = true
            tally.contourBlocks += try copyContours(.ways, into: writer, scratch: &scratch)
            let batch = inventedWays()
            writer.ways(batch)
            tally.addedWays = batch.count
        }

        guard let ready, ready.touched else {
            writer.copy(header: header, blob: blob)
            tally.copied += 1
            return
        }
        tally.rebuilt += 1
        tally.tagged += ready.tagged
        tally.dropped += ready.dropped
        tally.marked += ready.marked
        if let nodes = ready.nodes { writer.nodes(nodes) }
        if let ways = ready.ways { writer.ways(ways) }
    }
}
