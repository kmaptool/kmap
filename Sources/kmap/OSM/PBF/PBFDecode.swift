import Foundation

/// One blob decoded into its sink: the string table, then dense nodes, ways and
/// relations, each group only if the sink asked for it.
extension PBFReader {
    /// Decode buffers, filled and refilled block by block. One set per thread, never
    /// shared: the concurrent readers each make their own.
    struct Scratch {
        var refs = [Int64](), keys = [Int32](), values = [Int32]()
        var ids = [Int64](), lats = [Int64](), lons = [Int64](), tags = [Int32]()
        var roles = [Int32](), kinds = [Int32]()
    }

    /// Decodes one inflated PrimitiveBlock into a sink. The same decoder serves every pass
    /// and the rewriter, so they cannot disagree about deltas, tag runs or coordinates.
    static func decodeBlock<Sink: OSMSink>(_ bytes: UnsafeRawBufferPointer, into sink: inout Sink,
                                           fields: inout Scratch) throws {
        var block = OSMBlock()
        var words: [UnsafeRawBufferPointer] = []
        var groups: [UnsafeRawBufferPointer] = []
        var reader = ProtoReader(bytes)
        while let field = reader.nextField() {
            switch field.number {
            case Field.stringTable:
                var table = ProtoReader(reader.lengthDelimited())
                while let entry = table.nextField() {
                    if entry.number == Field.stringEntry {
                        words.append(table.lengthDelimited())
                    } else {
                        table.skip(wire: entry.wire)
                    }
                }
            case Field.primitiveGroup: groups.append(reader.lengthDelimited())
            // Bit patterns, not range-checked conversions: a corrupt value must give a
            // wrong coordinate rather than trap.
            case Field.granularity: block.granularity = Int64(bitPattern: reader.varint())
            case Field.latOffset: block.latOffset = Int64(bitPattern: reader.varint())
            case Field.lonOffset: block.lonOffset = Int64(bitPattern: reader.varint())
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
                case Field.groupDense:
                    sink.sawGroup(.nodes)
                    guard wanted.contains(.nodes) else { reader.skip(wire: field.wire); break }
                    decodeDense(reader.lengthDelimited(), block: block, into: &sink,
                                fields: &fields)
                case Field.groupWays:
                    sink.sawGroup(.ways)
                    guard wanted.contains(.ways) else { reader.skip(wire: field.wire); break }
                    decodeWay(reader.lengthDelimited(), block: block, into: &sink,
                              fields: &fields)
                case Field.groupRelations:
                    sink.sawGroup(.relations)
                    guard wanted.contains(.relations) else { reader.skip(wire: field.wire); break }
                    decodeRelation(reader.lengthDelimited(), block: block, into: &sink,
                                   fields: &fields)
                default: reader.skip(wire: field.wire)
                }
            }
        }
    }

    /// Dense nodes are packed and delta-encoded, with every node's tags in one flat run of
    /// key/value indices, each node's run closed by a zero.
    private static func decodeDense<Sink: OSMSink>(_ bytes: UnsafeRawBufferPointer, block: OSMBlock,
                                            into sink: inout Sink,
                                            fields: inout Scratch) {
        fields.ids.removeAll(keepingCapacity: true)
        fields.lats.removeAll(keepingCapacity: true)
        fields.lons.removeAll(keepingCapacity: true)
        fields.tags.removeAll(keepingCapacity: true)
        var reader = ProtoReader(bytes)
        while let field = reader.nextField() {
            switch field.number {
            case Field.denseID: Self.packedZigzag(reader.lengthDelimited(), into: &fields.ids)
            case Field.denseLat: Self.packedZigzag(reader.lengthDelimited(), into: &fields.lats)
            case Field.denseLon: Self.packedZigzag(reader.lengthDelimited(), into: &fields.lons)
            case Field.denseKeysVals:
                Self.packedVarint32(reader.lengthDelimited(), into: &fields.tags)
            default: reader.skip(wire: field.wire)
            }
        }
        // Local names for the scratch buffers; no copy is made.
        let ids = fields.ids, lats = fields.lats, lons = fields.lons, tags = fields.tags

        var id: Int64 = 0, lat: Int64 = 0, lon: Int64 = 0, cursor = 0
        for i in 0..<ids.count {
            // Wrapping: deltas summing past Int64.max in a corrupt file must give a wrong
            // node rather than trap.
            id &+= ids[i]
            lat &+= i < lats.count ? lats[i] : 0
            lon &+= i < lons.count ? lons[i] : 0
            // A pair needs both halves: stepping on a lone trailing key would run the
            // cursor past the end and trap on the slice below.
            let start = cursor
            while cursor + 1 < tags.count && tags[cursor] != 0 { cursor += 2 }
            let end = min(cursor, tags.count)
            if cursor < tags.count { cursor += 1 }              // step over the terminator
            sink.node(id: id, lat: block.latitude(lat), lon: block.longitude(lon),
                      tags: tags[start..<end], block: block)
        }
    }

    private static func decodeWay<Sink: OSMSink>(_ bytes: UnsafeRawBufferPointer, block: OSMBlock,
                                          into sink: inout Sink, fields: inout Scratch) {
        var id: Int64 = 0
        // Emptied, not replaced: assigning a new array would discard the kept capacity.
        fields.refs.removeAll(keepingCapacity: true)
        fields.keys.removeAll(keepingCapacity: true)
        fields.values.removeAll(keepingCapacity: true)
        var reader = ProtoReader(bytes)
        while let field = reader.nextField() {
            switch field.number {
            case Field.elementID: id = Int64(bitPattern: reader.varint())
            case Field.elementKeys:
                Self.packedVarint32(reader.lengthDelimited(), into: &fields.keys)
            case Field.elementVals:
                Self.packedVarint32(reader.lengthDelimited(), into: &fields.values)
            case Field.wayRefs:
                var delta: Int64 = 0
                var packed = ProtoReader(reader.lengthDelimited())
                while !packed.isAtEnd {
                    delta &+= packed.zigzag()
                    fields.refs.append(delta)
                }
            default: reader.skip(wire: field.wire)
            }
        }
        sink.way(id: id, refs: fields.refs[...], keys: fields.keys[...],
                 values: fields.values[...], block: block)
    }

    private static func decodeRelation<Sink: OSMSink>(_ bytes: UnsafeRawBufferPointer,
                                               block: OSMBlock, into sink: inout Sink,
                                               fields: inout Scratch) {
        var id: Int64 = 0
        fields.refs.removeAll(keepingCapacity: true)
        fields.keys.removeAll(keepingCapacity: true)
        fields.values.removeAll(keepingCapacity: true)
        fields.kinds.removeAll(keepingCapacity: true)
        fields.roles.removeAll(keepingCapacity: true)
        var reader = ProtoReader(bytes)
        while let field = reader.nextField() {
            switch field.number {
            case Field.elementID: id = Int64(bitPattern: reader.varint())
            case Field.elementKeys:
                Self.packedVarint32(reader.lengthDelimited(), into: &fields.keys)
            case Field.elementVals:
                Self.packedVarint32(reader.lengthDelimited(), into: &fields.values)
            case Field.memberRoles:
                Self.packedVarint32(reader.lengthDelimited(), into: &fields.roles)
            case Field.memberIDs:
                var delta: Int64 = 0
                var packed = ProtoReader(reader.lengthDelimited())
                while !packed.isAtEnd {
                    delta &+= packed.zigzag()
                    fields.refs.append(delta)
                }
            case Field.memberKinds:
                Self.packedVarint32(reader.lengthDelimited(), into: &fields.kinds)
            default: reader.skip(wire: field.wire)
            }
        }
        sink.relation(id: id, memberKinds: fields.kinds[...], memberIDs: fields.refs[...],
                      memberRoles: fields.roles[...], keys: fields.keys[...],
                      values: fields.values[...], block: block)
    }

    /// Appends into a buffer the caller owns and keeps. The reserve is half the byte
    /// count, these streams averaging near two bytes per varint; a buffer needing more
    /// grows once and stays grown.
    static func packedZigzag(_ bytes: UnsafeRawBufferPointer, into out: inout [Int64]) {
        if out.capacity < bytes.count / 2 { out.reserveCapacity(bytes.count / 2) }
        var reader = ProtoReader(bytes)
        while !reader.isAtEnd { out.append(reader.zigzag()) }
    }

    static func packedVarint32(_ bytes: UnsafeRawBufferPointer, into out: inout [Int32]) {
        if out.capacity < bytes.count / 2 { out.reserveCapacity(bytes.count / 2) }
        var reader = ProtoReader(bytes)
        while !reader.isAtEnd { out.append(Int32(truncatingIfNeeded: reader.varint())) }
    }
}
