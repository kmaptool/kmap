import Foundation

/// What the rewrite adds beyond the file's own blocks: the contour files folded in, and
/// the nodes and ways the repair invents.
extension PBFRewriter {
    enum Part { case nodes, ways }

    /// What a contour block holds, as bits of `contourKinds`.
    private static let holdsNodes: UInt8 = 1, holdsWays: UInt8 = 2

    /// Passes the node blocks, or the way blocks, of every contour file straight through,
    /// still deflated. The files are read in the order given, which is the order their id
    /// ranges were handed out, so ids still ascend.
    mutating func copyContours(_ part: Part, into writer: PBFWriter,
                              scratch: inout [UInt8]) throws -> Int {
        if contourKinds.count != contours.count {
            contourKinds = [[UInt8]](repeating: [], count: contours.count)
        }
        let wanted = part == .nodes ? Self.holdsNodes : Self.holdsWays
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
                    guard kind == PBFSchema.dataBlob else { return }
                    let holds: UInt8
                    if index < known.count {
                        holds = known[index]
                    } else {
                        let size = try PBFReader.inflate(blob, into: &scratch)
                        let block = try scratch.withUnsafeBytes {
                            try Block(UnsafeRawBufferPointer(rebasing: $0[0..<size]), fields: &fields)
                        }
                        holds = (block.hasNodes ? Self.holdsNodes : 0) | (block.hasWays ? Self.holdsWays : 0)
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

    func inventedNodes() -> [PBFWriter.Node] {
        var batch: [PBFWriter.Node] = []
        for bridge in plan.bridges {
            batch.append(PBFWriter.Node(id: bridge.node, lat: bridge.lat, lon: bridge.lon, tags: []))
            batch.append(PBFWriter.Node(
                id: bridge.node + 1, lat: bridge.middle.lat, lon: bridge.middle.lon,
                tags: [(Self.repairTag, bridge.word),
                       ("name", RepairLabel.sign(bridge.word, bridge.length, bridge.height, language))]))
        }
        return batch
    }

    func inventedWays() -> [PBFWriter.Way] {
        plan.bridges.map { bridge in
            PBFWriter.Way(id: bridge.node, refs: [bridge.end, bridge.node],
                          tags: [("highway", "path"), (Self.repairTag, bridge.word),
                                 ("name", RepairLabel.link(bridge.word, bridge.length,
                                                           bridge.height, language))])
        }
    }
}
