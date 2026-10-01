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
    static func decodeBlock<Sink: OSMSink>(
        _ bytes: UnsafeRawBufferPointer,
        into sink: inout Sink,
        fields: inout Scratch
    ) throws {
        var block = OSMBlock()
        var words: [UnsafeRawBufferPointer] = []
        var groups: [UnsafeRawBufferPointer] = []
        var reader = ProtoReader(bytes)
        while let field = reader.nextField() {
            switch field.number {
            case PBFSchema.stringTable:
                var table = ProtoReader(reader.lengthDelimited())
                while let entry = table.nextField() {
                    if entry.number == PBFSchema.stringEntry {
                        words.append(table.lengthDelimited())
                    } else {
                        table.skip(wire: entry.wire)
                    }
                }
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
        sink.begin(block)
        let wanted = sink.wantedParts
        for group in groups {
            var reader = ProtoReader(group)
            while let field = reader.nextField() {
                switch field.number {
                case PBFSchema.groupDense:
                    sink.sawGroup(.nodes)
                    guard wanted.contains(.nodes) else { reader.skip(wire: field.wire); break }
                    decodeDense(
                        reader.lengthDelimited(),
                        block: block,
                        into: &sink,
                        fields: &fields
                    )
                case PBFSchema.groupWays:
                    sink.sawGroup(.ways)
                    guard wanted.contains(.ways) else { reader.skip(wire: field.wire); break }
                    decodeWay(
                        reader.lengthDelimited(),
                        block: block,
                        into: &sink,
                        fields: &fields
                    )
                case PBFSchema.groupRelations:
                    sink.sawGroup(.relations)
                    guard wanted.contains(.relations) else { reader.skip(wire: field.wire); break }
                    decodeRelation(
                        reader.lengthDelimited(),
                        block: block,
                        into: &sink,
                        fields: &fields
                    )
                default: reader.skip(wire: field.wire)
                }
            }
        }
    }

    /// Dense nodes are packed and delta-encoded, with every node's tags in one flat run of
    /// key/value indices, each node's run closed by a zero.
    private static func decodeDense<Sink: OSMSink>(
        _ bytes: UnsafeRawBufferPointer,
        block: OSMBlock,
        into sink: inout Sink,
        fields: inout Scratch
    ) {
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
        // The buffers keep their full size; the counts say how much is in use.
        let ids = fields.ids.storage, lats = fields.lats.storage, lons = fields.lons.storage
        let tags = fields.tags.storage
        let idCount = fields.ids.count, latCount = fields.lats.count, lonCount = fields.lons.count
        let tagCount = fields.tags.count
        // Most nodes carry no tag: they are handed this, not a slice made for each.
        let noTags = ArraySlice<Int32>()

        ids.withUnsafeBufferPointer { ids in
            lats.withUnsafeBufferPointer { lats in
                lons.withUnsafeBufferPointer { lons in
                    var id: Int64 = 0, lat: Int64 = 0, lon: Int64 = 0, cursor = 0
                    for i in 0..<idCount {
                        // Wrapping: deltas summing past Int64.max in a corrupt file must
                        // give a wrong node rather than trap.
                        id &+= ids[i]
                        lat &+= i < latCount ? lats[i] : 0
                        lon &+= i < lonCount ? lons[i] : 0
                        // A pair needs both halves: stepping on a lone trailing key would
                        // run the cursor past the end and trap on the slice below.
                        let start = cursor
                        while cursor + 1 < tagCount && tags[cursor] != 0 { cursor += 2 }
                        let end = min(cursor, tagCount)
                        if cursor < tagCount { cursor += 1 }  // step over the terminator
                        // 2 calls, not 1 with a choice of slice in it: the choice is a
                        // copy, and a copy is a retain and a release for every node.
                        if start == end {
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
                                tags: tags[start..<end],
                                block: block
                            )
                        }
                    }
                }
            }
        }
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
