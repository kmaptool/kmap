import Foundation

/// Writes a repaired copy of a PBF. A block holding something this pass changes is
/// decoded, altered and written again; every other block is copied over as the compressed
/// bytes it already is.
struct PBFRewriter {
    enum Trouble: Error, CustomStringConvertible, LocalizedError {
        case mixedBlock
        case writesOverItsInput(String)

        var description: String {
            switch self {
            case .mixedBlock:
                "a block holds relations as well as nodes or ways, which this writer"
                    + " does not rebuild -- report the extract, it is not the usual layout"
            case .writesOverItsInput(let path):
                "\(path) is read while it is written: name another file for the output"
            }
        }

        /// Throws where `destination` is `source` or one of `others`, by any spelling: the
        /// output takes the input's place when it is done, and a file still being read
        /// will not move on Windows.
        static func refuseOverwriting(_ source: URL, _ others: [URL] = [], with destination: URL) throws {
            if ([source] + others).contains(where: destination.sameFile) {
                throw Trouble.writesOverItsInput(destination.nativePath)
            }
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
    /// Strips from names and descriptions what no code page draws: see `cleaned`.
    var cleanLabels = false
    /// Keeps the zero-width joiners in that cleaning, for the Arabic code page.
    var keepsJoiners = false
    /// With `cleanLabels`: mkgmap's name tags in order, and the code page they must read in.
    var nameOrder: [String] = []
    var codePage = CodePage.westernEuropean
    /// Whether names are swapped at all: a single-byte page kmap has a table for.
    private var renames: Bool { cleanLabels && !nameOrder.isEmpty && MkgmapUnreadable.pages[codePage] != nil }
    /// Areas repeating a venue already on the map, tagged so the style can hide the
    /// second icon.
    var duplicateVenues: Set<Int64> = []
    /// Contour files to fold into this one, in id order. splitter keeps ways complete only
    /// for its first input file, so contours handed to it separately are cut at every tile
    /// boundary they cross.
    var contours: [URL] = []
    /// Asked between batches of blocks: the rewrite runs on threads of its own, where a
    /// task's cancellation is not seen.
    var shouldStop: @Sendable () -> Bool = { false }

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
        var renamed = 0
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

        try Trouble.refuseOverwriting(url, contours, with: destination)
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
        var decoded = [RewriteBlock?](repeating: nil, count: width)
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
                if shouldStop() { throw CancellationError() }
                // A failed write, a full disk, fails the rest: no use reading on.
                if let failure = writer.writeFailure { throw failure }
                let items = batch
                let names = renames ? (order: nameOrder, codePage: codePage, keepingJoiners: keepsJoiners) : nil
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
                                    try RewriteBlock(
                                        UnsafeRawBufferPointer(rebasing: $0[0..<size]),
                                        fields: &fields[i],
                                        relations: tidyDescriptions || cleanLabels,
                                        names: names
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

        if !addedNodes { try addNodes(into: writer, tally: &tally, scratch: &scratch) }
        if !addedWays { try addWays(into: writer, tally: &tally, scratch: &scratch) }
        try writer.finish()
        return tally
    }

    /// A block prepared but not yet written. Touches neither the writer nor any running
    /// total, so it can be built on any thread.
    private struct Rebuilt {
        /// Nil when the block needs nothing and its bytes go through as they are.
        var nodes: [PBFWriter.Node]?
        var ways: [PBFWriter.Way]?
        var relations: [PBFWriter.Relation]?
        var tagged = 0
        var dropped = 0
        var marked = 0
        var renamed = 0
        var touched: Bool { nodes != nil || ways != nil || relations != nil }
    }

    /// Returns the block with repairs, barrier tags and tidied descriptions applied, or an
    /// untouched result if it needs none.
    /// - Throws: `Trouble.mixedBlock` when the block holds relations as well as ways.
    private func rebuild(
        _ block: RewriteBlock,
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
            || (cleanLabels && block.hasUnprintable
                && (!block.hasRelations || !(block.hasNodes || block.hasWays) || block.nodesOrWaysUnprintable))
            || block.needsRenaming
        guard touched else { return out }
        if block.hasRelations && (block.hasWays || block.hasNodes) { throw Trouble.mixedBlock }

        // A block may hold both nodes and ways.
        if block.hasNodes {
            var batch = block.nodes(movedBy: moved, filter: moveFilter)
            for i in batch.indices {
                if nodeFilter.mayContain(batch[i].id), let kind = barriers[batch[i].id] {
                    batch[i].tags.append((Self.barrierTag, kind))
                    out.tagged += 1
                }
                if tidyDescriptions { out.dropped += Self.tidy(&batch[i].tags) }
                out.renamed += relabel(&batch[i].tags, in: block)
            }
            out.nodes = batch
        }
        if block.hasWays {
            var batch = block.ways(
                inserting: inserts,
                merging: plan.merges,
                wayFilter: wayFilter,
                mergeFilter: mergeFilter
            )
            for i in batch.indices {
                if tidyDescriptions {
                    let stays = Self.wordStays(refs: batch[i].refs, tags: batch[i].tags)
                    out.dropped += Self.tidy(&batch[i].tags, wordStays: stays)
                }
                out.renamed += relabel(&batch[i].tags, in: block)
                if wayFilter.mayContain(batch[i].id), duplicateVenues.contains(batch[i].id) {
                    batch[i].tags.append((Self.duplicateVenueTag, "yes"))
                    out.marked += 1
                }
            }
            out.ways = batch
        }
        // Read only for tidying and cleaning; a block mixing them with nodes or ways was
        // refused above.
        if block.hasRelations && !block.relationIDs.isEmpty {
            var batch = block.relations()
            for i in batch.indices {
                if tidyDescriptions { out.dropped += Self.tidy(&batch[i].tags) }
                out.renamed += relabel(&batch[i].tags, in: block)
            }
            out.relations = batch
        }
        return out
    }

    /// Writes one prepared block. Runs in file order: it inserts this pass's own objects
    /// and updates the running totals.
    private mutating func write(
        _ ready: Rebuilt?,
        of block: RewriteBlock,
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
            // A block holding nodes as well as ways is written in two parts, so the
            // file's own nodes stay ahead of the added ones and every node ahead of
            // the ways.
            if block.hasNodes {
                // Relations are not read, so a block written again would lose them: refused
                // unless it is copied unchanged, with nothing written before it.
                if block.hasRelations {
                    guard ready?.touched != true, contours.isEmpty, inventedNodes().isEmpty, inventedWays().isEmpty
                    else { throw Trouble.mixedBlock }
                    addedWays = true
                    writer.copy(header: header, blob: blob)
                    tally.copied += 1
                    return
                }
                writer.nodes(ready?.nodes ?? block.nodes(movedBy: [:], filter: IDFilter()))
                try addNodes(into: writer, tally: &tally, scratch: &scratch)
                writer.ways(
                    ready?.ways
                        ?? block.ways(inserting: [:], merging: [:], wayFilter: IDFilter(), mergeFilter: IDFilter())
                )
                tally.rebuilt += 1
                count(ready, in: &tally)
                return
            }
            try addNodes(into: writer, tally: &tally, scratch: &scratch)
        }
        if block.hasRelations && !addedWays {
            addedWays = true
            try addWays(into: writer, tally: &tally, scratch: &scratch)
        }

        guard let ready, ready.touched else {
            writer.copy(header: header, blob: blob)
            tally.copied += 1
            return
        }
        tally.rebuilt += 1
        count(ready, in: &tally)
        if let nodes = ready.nodes { writer.nodes(nodes) }
        if let ways = ready.ways { writer.ways(ways) }
        if let relations = ready.relations { writer.relations(relations) }
    }

    /// Cleans an object's labels and swaps a name the code page cannot draw. Returns 1 where
    /// a name was swapped.
    private func relabel(_ tags: inout [(String, String)], in block: RewriteBlock) -> Int {
        guard cleanLabels else { return 0 }
        if block.hasUnprintable { Self.clean(&tags, keepingJoiners: keepsJoiners) }
        guard block.needsRenaming else { return 0 }
        return Self.chooseReadableName(&tags, order: nameOrder, codePage: codePage) ? 1 : 0
    }

    private func count(_ ready: Rebuilt?, in tally: inout Tally) {
        guard let ready else { return }
        tally.tagged += ready.tagged
        tally.dropped += ready.dropped
        tally.marked += ready.marked
        tally.renamed += ready.renamed
    }

    /// The nodes this pass invents, from 2^40, then the contour nodes, from 2^42: in that
    /// order the ids keep ascending, which the split's lookups rely on.
    private mutating func addNodes(into writer: PBFWriter, tally: inout Tally, scratch: inout [UInt8]) throws {
        let batch = inventedNodes()
        writer.nodes(batch)
        tally.addedNodes = batch.count
        tally.contourBlocks += try copyContours(.nodes, into: writer, scratch: &scratch)
    }

    private mutating func addWays(into writer: PBFWriter, tally: inout Tally, scratch: inout [UInt8]) throws {
        let batch = inventedWays()
        writer.ways(batch)
        tally.addedWays = batch.count
        tally.contourBlocks += try copyContours(.ways, into: writer, scratch: &scratch)
    }
}
