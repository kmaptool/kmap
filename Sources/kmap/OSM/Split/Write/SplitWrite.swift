import Foundation

/// The last pass: handing every object to the tiles that need it, and closing the files.
///
/// One walk of the extract per kind -- a tile's nodes must all precede its ways -- with
/// the decoding on every core and the handing over on the one thread that has to stay in
/// file order.
extension TileSplitter {
    func write(areas: [Area], assignment: Assignment, plan: Plan) throws -> [Int] {
        var writers: [TileWriter] = []
        for (index, area) in areas.enumerated() {
            let url = options.outputDirectory
                .appendingPathComponent("\(options.mapID + index).osm.pbf")
            writers.append(try TileWriter(url: url, area: area))
        }
        do {
            return try write(into: writers, assignment: assignment, plan: plan)
        } catch {
            // A tile half written looks whole to the next stage; none stays.
            for writer in writers {
                try? writer.finish()
                FileTools.removeIfPresent(writer.url)
            }
            throw error
        }
    }

    private func write(into writers: [TileWriter], assignment: Assignment, plan: Plan) throws -> [Int] {
        // 2 sweeps, so that with several inputs every tile still comes out nodes first,
        // then ways, then relations -- the order the format demands. Decoding a block and
        // choosing each object's tiles runs on every core; only the handing over stays in
        // file order, where the first copy of a repeat counts.
        try writeNodes(into: writers, assignment: assignment, plan: plan)
        if Measured.reported {
            log(String(format: "  nodes written, up to %@", Fmt.bytes(Machine.memoryInUse())))
        }
        try writeWaysAndRelations(into: writers, assignment: assignment, plan: plan)
        try Self.finish(writers)
        return writers.map(\.nodeCount)
    }

    /// A write pass for every block of `phase`.
    private func pass(
        _ phase: WritePass.Phase,
        assignment: Assignment,
        plan: Plan,
        planned: IDFilter,
        tiles: Int
    ) -> () -> WritePass {
        let overlapping = options.inputs.count > 1
        return {
            WritePass(
                nodes: assignment.nodes,
                cursor: NodeAreas.Cursor(assignment.nodes),
                plan: plan,
                plannedWays: planned,
                phase: phase,
                tiles: overlapping ? 0 : tiles
            )
        }
    }

    private func writeNodes(into writers: [TileWriter], assignment: Assignment, plan: Plan) throws {
        let overlapping = options.inputs.count > 1
        var repeats = NodeRepeats(assignment.nodes, inputs: options.inputs.count)
        for (fileIndex, input) in options.inputs.enumerated() {
            repeats.start(file: fileIndex)
            // Nodes ask nothing of the planned ways.
            let make = pass(.nodes, assignment: assignment, plan: plan, planned: IDFilter(), tiles: writers.count)
            try reader(input).readInOrder(make: make) { pass in
                for i in 0..<pass.nodeBuckets.count {
                    writers[Int(pass.nodeBuckets.tiles[i])].add(nodes: pass.nodeBuckets.chunks[i])
                }
                for (node, tile, span) in pass.outNodes {
                    if overlapping, repeats.repeated(node.id) { continue }
                    if tile == WritePass.several {
                        for one in pass.spans[Int(span)] { writers[Int(one)].add(node) }
                    } else {
                        writers[Int(tile)].add(node)
                    }
                }
                try Self.stopIfAnyFailed(writers)
            }
        }
    }

    private func writeWaysAndRelations(into writers: [TileWriter], assignment: Assignment, plan: Plan) throws {
        let overlapping = options.inputs.count > 1
        var seenWays: Set<Int64> = []
        var seenRelations: Set<Int64> = []
        // Few ways are planned for, and every way asks: the filter answers most of them.
        // Made once, for every input.
        let planned = IDFilter(Array(plan.wayTiles.keys))
        for input in options.inputs {
            let make = pass(
                .waysAndRelations,
                assignment: assignment,
                plan: plan,
                planned: planned,
                tiles: writers.count
            )
            try reader(input).readInOrder(make: make) { pass in
                for i in 0..<pass.wayBuckets.count {
                    writers[Int(pass.wayBuckets.tiles[i])].add(ways: pass.wayBuckets.chunks[i])
                }
                for (way, tile, span) in pass.outWays {
                    if overlapping, !seenWays.insert(way.id).inserted { continue }
                    if tile == WritePass.several {
                        for one in pass.spans[Int(span)] { writers[Int(one)].add(way) }
                    } else {
                        writers[Int(tile)].add(way)
                    }
                }
                for (relation, span) in pass.outRelations {
                    if overlapping, !seenRelations.insert(relation.id).inserted { continue }
                    for tile in pass.spans[Int(span)] { writers[Int(tile)].add(relation) }
                }
                try Self.stopIfAnyFailed(writers)
            }
        }
    }

    /// Each writer finishes independently: the last batches compress and the file closes
    /// per tile.
    private static func finish(_ writers: [TileWriter]) throws {
        var failures = [Error?](repeating: nil, count: writers.count)
        failures.withUnsafeMutableBufferPointer { slots in
            // Each lane finishes its own writer into its own slot: nothing is shared.
            nonisolated(unsafe) let slots = slots
            nonisolated(unsafe) let writers = writers
            DispatchQueue.concurrentPerform(iterations: writers.count) { index in
                do { try writers[index].finish() } catch { slots[index] = error }
            }
        }
        if let failure = failures.compactMap({ $0 }).first { throw failure }
    }

    /// A disk that filled during the first tile must not cost the sweep of the others.
    private static func stopIfAnyFailed(_ writers: [TileWriter]) throws {
        for writer in writers {
            if let failure = writer.failure { throw failure }
        }
    }

    // MARK: The two companion files

    func writeAreasList(
        _ tiles: [(mapID: String, area: Area, nodes: Int)],
        to url: URL
    ) throws {
        var text = "# List of areas\n# Generated by kmap\n#\n"
        for tile in tiles {
            let a = tile.area
            text += "\(tile.mapID): \(a.minLat),\(a.minLon) to \(a.maxLat),\(a.maxLon)\n"
            text += String(
                format: "#       : %f,%f to %f,%f\n\n",
                Self.degrees(a.minLat),
                Self.degrees(a.minLon),
                Self.degrees(a.maxLat),
                Self.degrees(a.maxLon)
            )
        }
        try FileTools.write(text, to: url)
    }

    func writeTemplateArgs(
        _ tiles: [(mapID: String, area: Area, nodes: Int)],
        to url: URL
    ) throws {
        var text = "#\n# This file can be given to mkgmap using the -c option\n#\n"
        for tile in tiles {
            text += "\nmapname: \(tile.mapID)\n"
            text += "description: \(options.description)\n"
            text += "input-file: \(tile.mapID).osm.pbf\n"
        }
        try FileTools.write(text, to: url)
    }
}
