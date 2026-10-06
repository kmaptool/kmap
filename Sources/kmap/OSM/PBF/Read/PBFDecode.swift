import Foundation

/// One blob decoded into its sink: the string table, then dense nodes, ways and
/// relations, each group only if the sink asked for it.
extension PBFReader {
    /// Decode buffers, filled and refilled block by block. One set per thread, never
    /// shared: the concurrent readers each make their own.
    struct Scratch {
        var refs = ReusedBuffer<Int64>(zero: 0)
        var keys = ReusedBuffer<Int32>(zero: 0), values = ReusedBuffer<Int32>(zero: 0)
        var ids = ReusedBuffer<Int64>(zero: 0)
        var lats = ReusedBuffer<Int64>(zero: 0), lons = ReusedBuffer<Int64>(zero: 0)
        var tags = ReusedBuffer<Int32>(zero: 0)
        var roles = ReusedBuffer<Int32>(zero: 0), kinds = ReusedBuffer<Int32>(zero: 0)
    }

    @inline(__always)
    private static func zigzags(_ bytes: UnsafeRawBufferPointer, into out: inout ReusedBuffer<Int64>) {
        out.append(atMost: bytes.count) { PackedVarints.zigzag(bytes, into: $0) }
    }

    @inline(__always)
    private static func zigzagSums(_ bytes: UnsafeRawBufferPointer, into out: inout ReusedBuffer<Int64>) {
        out.append(atMost: bytes.count) { PackedVarints.zigzagSums(bytes, into: $0) }
    }

    @inline(__always)
    private static func int32s(_ bytes: UnsafeRawBufferPointer, into out: inout ReusedBuffer<Int32>) {
        out.append(atMost: bytes.count) { PackedVarints.int32(bytes, into: $0) }
    }

    /// Decodes one inflated PrimitiveBlock into a sink. The same decoder serves every pass
    /// and the rewriter, so they cannot disagree about deltas, tag runs or coordinates.
    /// - Returns: every kind of group the block holds, asked for or not.
    @discardableResult
    static func decodeBlock<Sink: OSMSink>(
        _ bytes: UnsafeRawBufferPointer,
        into sink: inout Sink,
        fields: inout Scratch
    ) throws -> OSMParts {
        let (block, groups) = blockHeader(bytes)
        sink.begin(block)
        let wanted = sink.wantedParts
        var held: OSMParts = []
        for group in groups {
            held.formUnion(try decodeGroup(group, block: block, wanted: wanted, into: &sink, fields: &fields))
        }
        sink.end(block)
        return held
    }

    /// The block's string table and coordinate frame, and its groups still unread.
    private static func blockHeader(_ bytes: UnsafeRawBufferPointer) -> (OSMBlock, [UnsafeRawBufferPointer]) {
        var block = OSMBlock()
        var words: [UnsafeRawBufferPointer] = []
        var groups: [UnsafeRawBufferPointer] = []
        var reader = ProtoReader(bytes)
        while let field = reader.nextField() {
            switch field.number {
            case PBFSchema.stringTable: readStrings(reader.lengthDelimited(), into: &words)
            case PBFSchema.primitiveGroup: groups.append(reader.lengthDelimited())
            // Bit patterns, not range-checked conversions: a corrupt value must give a
            // wrong coordinate rather than trap.
            case PBFSchema.granularity: block.granularity = Int64(bitPattern: reader.varint())
            case PBFSchema.latOffset: block.latOffset = Int64(bitPattern: reader.varint())
            case PBFSchema.lonOffset: block.lonOffset = Int64(bitPattern: reader.varint())
            default: reader.skip(wire: field.wire)
            }
        }
        block.strings = StringPool(words)
        return (block, groups)
    }

    private static func readStrings(_ bytes: UnsafeRawBufferPointer, into words: inout [UnsafeRawBufferPointer]) {
        var table = ProtoReader(bytes)
        while let entry = table.nextField() {
            if entry.number == PBFSchema.stringEntry {
                words.append(table.lengthDelimited())
            } else {
                table.skip(wire: entry.wire)
            }
        }
    }

    /// Which part a group's field holds, or nil for a field that holds none.
    private static func part(of field: Int) -> OSMParts? {
        switch field {
        case PBFSchema.groupDense: return .nodes
        case PBFSchema.groupWays: return .ways
        case PBFSchema.groupRelations: return .relations
        default: return nil
        }
    }

    /// Decodes the parts of 1 group the sink asks for, and reports every part it holds.
    private static func decodeGroup<Sink: OSMSink>(
        _ group: UnsafeRawBufferPointer,
        block: OSMBlock,
        wanted: OSMParts,
        into sink: inout Sink,
        fields: inout Scratch
    ) throws -> OSMParts {
        var held: OSMParts = []
        var reader = ProtoReader(group)
        while let field = reader.nextField() {
            // Nodes 1 message each, as some writers can be told to write: refused rather than
            // read as none, which would lose every node of the file without a word.
            if field.number == PBFSchema.groupNodes { throw PBFError.plainNodes }
            guard let part = part(of: field.number) else {
                reader.skip(wire: field.wire)
                continue
            }
            held.insert(part)
            sink.sawGroup(part)
            guard wanted.contains(part) else {
                reader.skip(wire: field.wire)
                continue
            }
            let bytes = reader.lengthDelimited()
            switch part {
            case .nodes: decodeDense(bytes, block: block, into: &sink, fields: &fields)
            case .ways: decodeWay(bytes, block: block, into: &sink, fields: &fields)
            default: decodeRelation(bytes, block: block, into: &sink, fields: &fields)
            }
        }
        return held
    }

    /// Dense nodes are packed and delta-encoded, with every node's tags in one flat run of
    /// key/value indices, each node's run closed by a zero.
    private static func decodeDense<Sink: OSMSink>(
        _ bytes: UnsafeRawBufferPointer,
        block: OSMBlock,
        into sink: inout Sink,
        fields: inout Scratch
    ) {
        readDense(bytes, into: &fields)
        // The buffers keep their full size; the counts say how much is in use.
        let tags = fields.tags.storage
        let tagCount = fields.tags.count
        let latCount = fields.lats.count, lonCount = fields.lons.count
        // Most nodes carry no tag: they are handed this, not a slice made for each.
        let noTags = ArraySlice<Int32>()
        let idCount = fields.ids.count
        fields.ids.storage.withUnsafeBufferPointer { ids in
            fields.lats.storage.withUnsafeBufferPointer { lats in
                fields.lons.storage.withUnsafeBufferPointer { lons in
                    var id: Int64 = 0, lat: Int64 = 0, lon: Int64 = 0, cursor = 0
                    for i in 0..<idCount {
                        // Wrapping: deltas summing past Int64.max in a corrupt file must
                        // give a wrong node rather than trap.
                        id &+= ids[i]
                        lat &+= i < latCount ? lats[i] : 0
                        lon &+= i < lonCount ? lons[i] : 0
                        let run = tagRun(tags, count: tagCount, from: &cursor)
                        // 2 calls, not 1 with a choice of slice in it: the choice is a
                        // copy, and a copy is a retain and a release for every node.
                        if run.isEmpty {
                            sink.node(
                                id: id,
                                lat: block.latitude(lat),
                                lon: block.longitude(lon),
                                tags: noTags,
                                block: block
                            )
                        } else {
                            sink.node(
                                id: id,
                                lat: block.latitude(lat),
                                lon: block.longitude(lon),
                                tags: tags[run],
                                block: block
                            )
                        }
                    }
                }
            }
        }
    }

    /// The dense group's packed fields, unpacked into `fields`.
    private static func readDense(_ bytes: UnsafeRawBufferPointer, into fields: inout Scratch) {
        fields.ids.removeAll()
        fields.lats.removeAll()
        fields.lons.removeAll()
        fields.tags.removeAll()
        var reader = ProtoReader(bytes)
        while let field = reader.nextField() {
            switch field.number {
            case PBFSchema.denseID: Self.zigzags(reader.lengthDelimited(), into: &fields.ids)
            case PBFSchema.denseLat: Self.zigzags(reader.lengthDelimited(), into: &fields.lats)
            case PBFSchema.denseLon: Self.zigzags(reader.lengthDelimited(), into: &fields.lons)
            case PBFSchema.denseKeysVals: Self.int32s(reader.lengthDelimited(), into: &fields.tags)
            default: reader.skip(wire: field.wire)
            }
        }
    }

    /// The next node's key/value run in the dense tags, the cursor stepped past its zero.
    @inline(__always)
    private static func tagRun(_ tags: [Int32], count: Int, from cursor: inout Int) -> Range<Int> {
        // A pair needs both halves: stepping on a lone trailing key would run the cursor
        // past the end and trap on the slice.
        let start = cursor
        while cursor + 1 < count && tags[cursor] != 0 { cursor += 2 }
        let end = min(cursor, count)
        if cursor < count { cursor += 1 }  // step over the terminator
        return start..<end
    }

    private static func decodeWay<Sink: OSMSink>(
        _ bytes: UnsafeRawBufferPointer,
        block: OSMBlock,
        into sink: inout Sink,
        fields: inout Scratch
    ) {
        var id: Int64 = 0
        fields.refs.removeAll()
        fields.keys.removeAll()
        fields.values.removeAll()
        var reader = ProtoReader(bytes)
        while let field = reader.nextField() {
            switch field.number {
            case PBFSchema.elementID: id = Int64(bitPattern: reader.varint())
            case PBFSchema.elementKeys: Self.int32s(reader.lengthDelimited(), into: &fields.keys)
            case PBFSchema.elementVals: Self.int32s(reader.lengthDelimited(), into: &fields.values)
            case PBFSchema.wayRefs:
                // A field in 2 pieces starts its sums again.
                Self.zigzagSums(reader.lengthDelimited(), into: &fields.refs)
            default: reader.skip(wire: field.wire)
            }
        }
        sink.way(
            id: id,
            refs: fields.refs.slice,
            keys: fields.keys.slice,
            values: fields.values.slice,
            block: block
        )
    }

    private static func decodeRelation<Sink: OSMSink>(
        _ bytes: UnsafeRawBufferPointer,
        block: OSMBlock,
        into sink: inout Sink,
        fields: inout Scratch
    ) {
        var id: Int64 = 0
        fields.refs.removeAll()
        fields.keys.removeAll()
        fields.values.removeAll()
        fields.kinds.removeAll()
        fields.roles.removeAll()
        var reader = ProtoReader(bytes)
        while let field = reader.nextField() {
            switch field.number {
            case PBFSchema.elementID: id = Int64(bitPattern: reader.varint())
            case PBFSchema.elementKeys: Self.int32s(reader.lengthDelimited(), into: &fields.keys)
            case PBFSchema.elementVals: Self.int32s(reader.lengthDelimited(), into: &fields.values)
            case PBFSchema.memberRoles: Self.int32s(reader.lengthDelimited(), into: &fields.roles)
            case PBFSchema.memberIDs: Self.zigzagSums(reader.lengthDelimited(), into: &fields.refs)
            case PBFSchema.memberKinds: Self.int32s(reader.lengthDelimited(), into: &fields.kinds)
            default: reader.skip(wire: field.wire)
            }
        }
        sink.relation(
            id: id,
            memberKinds: fields.kinds.slice,
            memberIDs: fields.refs.slice,
            memberRoles: fields.roles.slice,
            keys: fields.keys.slice,
            values: fields.values.slice,
            block: block
        )
    }
}
