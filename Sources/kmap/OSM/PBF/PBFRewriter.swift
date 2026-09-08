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

    private enum Part { case nodes, ways }

    /// What each contour file's data blobs hold, recorded on the first walk: bit 0 nodes,
    /// bit 1 ways. The files are walked twice, nodes before ways.
    var contourKinds: [[UInt8]] = []

    /// Passes the node blocks, or the way blocks, of every contour file straight through,
    /// still deflated. The files are read in the order given, which is the order their id
    /// ranges were handed out, so ids still ascend.
    private mutating func copyContours(_ part: Part, into writer: PBFWriter,
                              scratch: inout [UInt8]) throws -> Int {
        if contourKinds.count != contours.count {
            contourKinds = [[UInt8]](repeating: [], count: contours.count)
        }
        let wanted: UInt8 = part == .nodes ? 1 : 2
        var count = 0
        for (at, file) in contours.enumerated() {
            let known = contourKinds[at]
            var kinds = known
            var index = 0
            var fields = PBFReader.Scratch()
            let data = try Data(contentsOf: file, options: .alwaysMapped)
            var written = 0
            try data.withUnsafeBytes { bytes in
                try PBFReader.forEachBlob(in: bytes) { header, kind, blob in
                    // Each contour file carries its own OSMHeader; the one already written
                    // stands for the lot.
                    guard kind == "OSMData" else { return }
                    let holds: UInt8
                    if index < known.count {
                        holds = known[index]
                    } else {
                        let size = try PBFReader.inflate(blob, into: &scratch)
                        let block = try scratch.withUnsafeBytes {
                            try Block(UnsafeRawBufferPointer(rebasing: $0[0..<size]), fields: &fields)
                        }
                        holds = (block.hasNodes ? 1 : 0) | (block.hasWays ? 2 : 0)
                        kinds.append(holds)
                    }
                    index += 1
                    guard holds & wanted != 0 else { return }
                    writer.copy(header: header, blob: blob)
                    written += 1
                }
            }
            contourKinds[at] = kinds
            count += written
        }
        return count
    }

    mutating func write(to destination: URL) throws -> Tally {
        // A cheap rejection test in front of the tables. Nodes and ways are filtered
        // separately: a node id and a way id may be the same number.
        let nodeFilter = IDFilter(Array(plan.moves.keys) + Array(barriers.keys))
        let wayFilter = IDFilter(Array(plan.inserts.keys.map { network.wayID[Int($0)] })
                                 + Array(duplicateVenues))
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
        var scratch = [UInt8](repeating: 0, count: 32 << 20)

        // Blocks are inflated and decoded a batch at a time across every core, then acted
        // on in file order: objects this pass adds go into the first block of their kind.
        let width = Machine.readers
        var scratches = [[UInt8]](repeating: [], count: width)
        // One set of decode buffers per slot, kept for the whole file.
        var fieldSets = (0..<width).map { _ in PBFReader.Scratch() }
        var decoded = [Block?](repeating: nil, count: width)
        var prepared = [Rebuilt?](repeating: nil, count: width)
        var failures = [Error?](repeating: nil, count: width)
        var batch: [(header: UnsafeRawBufferPointer, blob: UnsafeRawBufferPointer,
                     isData: Bool)] = []
        batch.reserveCapacity(width)

        try data.withUnsafeBytes { file in
            func decodeBatch() throws {
                guard !batch.isEmpty else { return }
                let items = batch
                scratches.withUnsafeMutableBufferPointer { buffers in
                    fieldSets.withUnsafeMutableBufferPointer { fields in
                    decoded.withUnsafeMutableBufferPointer { blocks in
                        failures.withUnsafeMutableBufferPointer { errors in
                            DispatchQueue.concurrentPerform(iterations: items.count) { i in
                                blocks[i] = nil
                                guard items[i].isData else { return }
                                do {
                                    let size = try PBFReader.inflate(items[i].blob,
                                                                     into: &buffers[i])
                                    blocks[i] = try buffers[i].withUnsafeBytes {
                                        try Block(UnsafeRawBufferPointer(rebasing: $0[0..<size]),
                                                  fields: &fields[i])
                                    }
                                } catch {
                                    errors[i] = error
                                }
                            }
                        }
                    }
                    }
                }
                if let failure = failures.prefix(items.count).compactMap({ $0 }).first {
                    failures = [Error?](repeating: nil, count: width)
                    throw failure
                }
                // Deciding whether a block needs rebuilding, and rebuilding it, depends on
                // nothing but the block and the tables, so it runs on every core.
                prepared.withUnsafeMutableBufferPointer { slots in
                    failures.withUnsafeMutableBufferPointer { errors in
                        DispatchQueue.concurrentPerform(iterations: items.count) { i in
                            slots[i] = nil
                            guard let block = decoded[i] else { return }
                            do {
                                slots[i] = try rebuild(block, moved: moved, inserts: inserts,
                                                       nodeFilter: nodeFilter,
                                                       wayFilter: wayFilter,
                                                       mergeFilter: mergeFilter,
                                                       moveFilter: moveFilter)
                            } catch {
                                errors[i] = error
                            }
                        }
                    }
                }
                if let failure = failures.prefix(items.count).compactMap({ $0 }).first {
                    failures = [Error?](repeating: nil, count: width)
                    throw failure
                }
                for i in 0..<items.count {
                    guard let block = decoded[i] else {
                        // Not an OSMData blob: the file header, straight through.
                        writer.copy(header: items[i].header, blob: items[i].blob)
                        tally.copied += 1
                        continue
                    }
                    try write(prepared[i], of: block, header: items[i].header,
                              blob: items[i].blob, writer: writer, tally: &tally,
                              scratch: &scratch, addedNodes: &addedNodes,
                              addedWays: &addedWays)
                }
                batch.removeAll(keepingCapacity: true)
            }

            try PBFReader.forEachBlob(in: file) { header, kind, blob in
                batch.append((header, blob, kind == "OSMData"))
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
    private func rebuild(_ block: Block,
                         moved: [Int64: (lat: Double, lon: Double)],
                         inserts: [Int64: [(after: Int64, segment: Int32, along: Double, node: Int64)]],
                         nodeFilter: IDFilter, wayFilter: IDFilter,
                         mergeFilter: IDFilter, moveFilter: IDFilter) throws -> Rebuilt {
        var out = Rebuilt()
        let touched = block.nodeIDs.contains {
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
                    batch[i].tags.append(("kmap:on", kind))
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
                    batch[i].tags.append(("kmap:dup_venue", "yes"))
                    out.marked += 1
                }
            }
            out.ways = batch
        }
        return out
    }

    /// Writes one prepared block. Runs in file order: it inserts this pass's own objects
    /// and updates the running totals.
    private mutating func write(_ ready: Rebuilt?, of block: Block,
                       header: UnsafeRawBufferPointer, blob: UnsafeRawBufferPointer,
                       writer: PBFWriter, tally: inout Tally, scratch: inout [UInt8],
                       addedNodes: inout Bool, addedWays: inout Bool) throws {
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

    /// Drops any description that only repeats the name, and returns how many were
    /// dropped. mkgmap cannot compare two tags, so this happens before the build.
    static func tidy(_ tags: inout [(String, String)]) -> Int {
        guard let name = Self.comparableName(tags) else { return 0 }
        let before = tags.count
        tags.removeAll { Self.saysNothingNew($0, $1, beside: name) }
        return before - tags.count
    }

    /// Whether `tidy` would drop anything, without building the tidied list.
    static func wouldTidy(_ tags: [(String, String)]) -> Bool {
        guard let name = Self.comparableName(tags) else { return false }
        return tags.contains { saysNothingNew($0.0, $0.1, beside: name) }
    }

    /// The name a description is measured against, folded for comparison.
    private static func comparableName(_ tags: [(String, String)]) -> String? {
        guard let name = tags.first(where: { $0.0 == "name" || $0.0 == "name:ru" })?.1,
              !name.isEmpty else { return nil }
        let folded = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return folded.isEmpty ? nil : folded
    }

    private static func saysNothingNew(_ key: String, _ value: String,
                                       beside name: String) -> Bool {
        guard key == "description" || key == "description:ru" || key == "description:en" else {
            return false
        }
        let described = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if described.isEmpty || described == name { return true }
        return (described.contains(name) || name.contains(described))
            && abs(described.count - name.count) < 6
    }

    private func inventedNodes() -> [PBFWriter.Node] {
        var batch: [PBFWriter.Node] = []
        for bridge in plan.bridges {
            batch.append(PBFWriter.Node(id: bridge.node, lat: bridge.lat, lon: bridge.lon, tags: []))
            batch.append(PBFWriter.Node(
                id: bridge.node + 1, lat: bridge.middle.lat, lon: bridge.middle.lon,
                tags: [("kmap:repair", bridge.word),
                       ("name", RepairLabel.sign(bridge.word, bridge.length, bridge.height, language))]))
        }
        return batch
    }

    private func inventedWays() -> [PBFWriter.Way] {
        plan.bridges.map { bridge in
            PBFWriter.Way(id: bridge.node, refs: [bridge.end, bridge.node],
                          tags: [("highway", "path"), ("kmap:repair", bridge.word),
                                 ("name", RepairLabel.link(bridge.word, bridge.length,
                                                           bridge.height, language))])
        }
    }
}
