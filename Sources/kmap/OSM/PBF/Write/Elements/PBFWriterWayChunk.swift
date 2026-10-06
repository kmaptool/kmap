import Foundation

extension PBFWriter {
    /// Ways handed over in runs, as `NodeChunk` hands over nodes.
    struct WayChunk: Sendable {
        var ids: [Int64] = []
        /// Where each way's nodes end in `refs`.
        var refEnds: [Int32] = []
        var refs: [Int64] = []
        var tagEnds: [Int32] = []
        var tags: [Int32] = []
        var strings: [String] = []

        var count: Int { ids.count }

        func ways(_ range: Range<Int>) -> [Way] {
            range.map { at in
                let start = at == 0 ? 0 : Int(tagEnds[at - 1])
                let pairs = stride(from: start, to: Int(tagEnds[at]), by: 2).map {
                    (strings[Int(tags[$0])], strings[Int(tags[$0 + 1])])
                }
                let first = at == 0 ? 0 : Int(refEnds[at - 1])
                return Way(id: ids[at], refs: Array(refs[first..<Int(refEnds[at])]), tags: pairs)
            }
        }
    }

    /// Writes a batch of way runs as `ways(_:)` writes the same ways one by one.
    func ways(runs: [(chunk: WayChunk, range: Range<Int>)]) {
        let total = runs.reduce(0) { $0 + $1.range.count }
        guard total > 0 else { return }
        submit {
            guard total <= Self.maxElementsPerBlock else {
                return Self.wayPieces(runs.flatMap { $0.chunk.ways($0.range) })
            }
            return [.toCompress(kind: PBFSchema.dataBlob, payload: Self.wayBlock(runs, count: total))]
        }
    }

    private static func wayBlock(_ runs: [(chunk: WayChunk, range: Range<Int>)], count: Int) -> [UInt8] {
        var strings = StringTable()
        var bodies: [[UInt8]] = []
        bodies.reserveCapacity(count)
        var keys = ProtoWriter(), values = ProtoWriter(), refs = ProtoWriter()
        var known: [Int32] = []
        for (chunk, range) in runs {
            known.removeAll(keepingCapacity: true)
            known.append(contentsOf: repeatElement(-1, count: chunk.strings.count))
            for at in range {
                keys.reset(); values.reset(); refs.reset()
                var tag = at == 0 ? 0 : Int(chunk.tagEnds[at - 1])
                let tagEnd = Int(chunk.tagEnds[at])
                while tag < tagEnd {
                    let key = Int(chunk.tags[tag]), value = Int(chunk.tags[tag + 1])
                    if known[key] < 0 { known[key] = strings.index(chunk.strings[key]) }
                    keys.varint(UInt64(known[key]))
                    if known[value] < 0 { known[value] = strings.index(chunk.strings[value]) }
                    values.varint(UInt64(known[value]))
                    tag += 2
                }
                var last: Int64 = 0
                for ref in (at == 0 ? 0 : Int(chunk.refEnds[at - 1]))..<Int(chunk.refEnds[at]) {
                    refs.zigzag(chunk.refs[ref] &- last)
                    last = chunk.refs[ref]
                }
                var body = ProtoWriter()
                body.reserve(keys.bytes.count + values.bytes.count + refs.bytes.count + Self.wayBodySlack)
                body.varintField(PBFSchema.elementID, chunk.ids[at])
                if !keys.bytes.isEmpty {
                    body.bytesField(PBFSchema.elementKeys, keys.bytes)
                    body.bytesField(PBFSchema.elementVals, values.bytes)
                }
                body.bytesField(PBFSchema.wayRefs, refs.bytes)
                bodies.append(body.bytes)
            }
        }
        return block(strings: strings) { group in
            for body in bodies { group.bytesField(PBFSchema.groupWays, body) }
        }
    }
}
