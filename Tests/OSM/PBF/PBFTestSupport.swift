import Foundation
import XCTest

@testable import kmap

/// Everything a file gave back, in the order the reader handed it over.
struct CollectedElements: OSMSink {
    var nodes: [(id: Int64, lat: Double, lon: Double, tags: [(String, String)])] = []
    var ways: [(id: Int64, refs: [Int64], tags: [(String, String)])] = []
    var relations: [(id: Int64, kinds: [Int32], ids: [Int64], roles: [String], tags: [(String, String)])] = []

    mutating func node(id: Int64, lat: Double, lon: Double, tags: ArraySlice<Int32>, block: OSMBlock) {
        var pairs: [(String, String)] = []
        var i = tags.startIndex
        while i + 1 < tags.endIndex {
            pairs.append((block.text(Int(tags[i])), block.text(Int(tags[i + 1]))))
            i += 2
        }
        nodes.append((id, lat, lon, pairs))
    }

    mutating func way(
        id: Int64,
        refs: ArraySlice<Int64>,
        keys: ArraySlice<Int32>,
        values: ArraySlice<Int32>,
        block: OSMBlock
    ) {
        ways.append((id, refs.exactly, zip(keys, values).map { (block.text(Int($0)), block.text(Int($1))) }))
    }

    mutating func relation(
        id: Int64,
        memberKinds: ArraySlice<Int32>,
        memberIDs: ArraySlice<Int64>,
        memberRoles: ArraySlice<Int32>,
        keys: ArraySlice<Int32>,
        values: ArraySlice<Int32>,
        block: OSMBlock
    ) {
        relations.append(
            (
                id, memberKinds.exactly, memberIDs.exactly,
                memberRoles.map { block.text(Int($0)) },
                zip(keys, values).map { (block.text(Int($0)), block.text(Int($1))) }
            )
        )
    }
}

/// The kind and id of every element, in the order they arrived: for tests about order.
struct ElementSequence: OSMSink {
    var seen: [(kind: Character, id: Int64)] = []

    mutating func node(id: Int64, lat: Double, lon: Double, tags: ArraySlice<Int32>, block: OSMBlock) {
        seen.append(("n", id))
    }

    mutating func way(
        id: Int64,
        refs: ArraySlice<Int64>,
        keys: ArraySlice<Int32>,
        values: ArraySlice<Int32>,
        block: OSMBlock
    ) {
        seen.append(("w", id))
    }

    mutating func relation(
        id: Int64,
        memberKinds: ArraySlice<Int32>,
        memberIDs: ArraySlice<Int64>,
        memberRoles: ArraySlice<Int32>,
        keys: ArraySlice<Int32>,
        values: ArraySlice<Int32>,
        block: OSMBlock
    ) {
        seen.append(("r", id))
    }

    /// Whether every node comes before the first way.
    var nodesPrecedeWays: Bool {
        guard let firstWay = seen.firstIndex(where: { $0.kind == "w" }) else { return true }
        return !seen[firstWay...].contains { $0.kind == "n" }
    }
}

/// Bytes of a PBF built by hand, field by field, so reader and writer cannot share a
/// misunderstanding.
enum PBFBytes {
    /// A blob carrying its payload uncompressed, as the format allows, with its frame.
    static func rawBlob(kind: String, payload: [UInt8]) -> [UInt8] {
        var blob = ProtoWriter()
        blob.bytesField(PBFSchema.blobRaw, payload)
        var header = ProtoWriter()
        header.stringField(PBFSchema.blobHeaderKind, kind)
        header.varintField(PBFSchema.blobHeaderSize, Int64(blob.bytes.count))
        return framed(header: header.bytes) + blob.bytes
    }

    /// The four-byte big-endian length in front of a BlobHeader.
    static func framed(header: [UInt8]) -> [UInt8] {
        var big = UInt32(header.count).bigEndian
        var out: [UInt8] = []
        withUnsafeBytes(of: &big) { out.append(contentsOf: $0) }
        return out + header
    }

    /// A PrimitiveBlock with dense nodes and ways in one group, which kmap's writer never
    /// produces but other tools may. Coordinates in degrees.
    static func mixedBlock(
        nodes: [(id: Int64, lat: Double, lon: Double)],
        ways: [(id: Int64, refs: [Int64])]
    ) -> [UInt8] {
        func deltas(_ values: [Int64]) -> [UInt8] {
            var w = ProtoWriter()
            var previous: Int64 = 0
            for value in values {
                w.zigzag(value &- previous)
                previous = value
            }
            return w.bytes
        }
        var block = ProtoWriter()
        block.message(PBFSchema.stringTable) { $0.stringField(PBFSchema.stringEntry, "") }
        block.message(PBFSchema.primitiveGroup) { group in
            if !nodes.isEmpty {
                group.message(PBFSchema.groupDense) { dense in
                    dense.bytesField(PBFSchema.denseID, deltas(nodes.map(\.id)))
                    dense.bytesField(PBFSchema.denseLat, deltas(nodes.map { Int64(($0.lat * 1e7).rounded()) }))
                    dense.bytesField(PBFSchema.denseLon, deltas(nodes.map { Int64(($0.lon * 1e7).rounded()) }))
                }
            }
            for way in ways {
                group.message(PBFSchema.groupWays) { out in
                    out.varintField(PBFSchema.elementID, way.id)
                    out.bytesField(PBFSchema.wayRefs, deltas(way.refs))
                }
            }
        }
        return block.bytes
    }
}

/// A seeded generator, so a fuzzing run repeats.
struct SplitMix64: RandomNumberGenerator {
    var state: UInt64

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
