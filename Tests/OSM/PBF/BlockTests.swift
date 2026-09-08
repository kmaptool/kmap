import XCTest
@testable import kmap

/// Decoding a PrimitiveBlock -- the unit an OSM PBF is made of.
///
/// Blocks are built field by field from the format's own definition, not with kmap's
/// writer, so reader and writer cannot share a misunderstanding.
final class BlockTests: XCTestCase {

    // MARK: Building blocks by hand

    /// Fields of PrimitiveBlock, DenseNodes and Way, from the OSM PBF schema.
    private enum Field {
        static let stringTable = 1, primitiveGroup = 2
        static let granularity = 17, latOffset = 19, lonOffset = 20
        static let denseNodes = 2, ways = 3, relations = 4
        static let denseID = 1, denseLat = 8, denseLon = 9, denseKeysVals = 10
        static let wayID = 1, wayKeys = 2, wayVals = 3, wayRefs = 8
        static let stringEntry = 1
    }

    private struct DenseNode {
        var id: Int64
        var lat: Int64            // in granularity units, before the offset
        var lon: Int64
        var tags: [(Int, Int)] = []   // indices into the string table
    }

    private struct RawWay {
        var id: Int64
        var refs: [Int64]
        var tags: [(Int, Int)] = []
    }

    /// A PrimitiveBlock as bytes. Every argument defaults, so a test names only what it
    /// is about.
    private func block(strings: [String] = [""],
                       granularity: Int64? = nil,
                       latOffset: Int64? = nil,
                       lonOffset: Int64? = nil,
                       nodes: [DenseNode] = [],
                       ways: [RawWay] = [],
                       relations: Int = 0,
                       rawKeysVals: [Int64]? = nil) -> [UInt8] {
        var w = ProtoWriter()
        w.message(Field.stringTable) { table in
            for s in strings { table.stringField(Field.stringEntry, s) }
        }
        if let granularity { w.varintField(Field.granularity, granularity) }
        if let latOffset { w.varintField(Field.latOffset, latOffset) }
        if let lonOffset { w.varintField(Field.lonOffset, lonOffset) }

        w.message(Field.primitiveGroup) { group in
            if !nodes.isEmpty || rawKeysVals != nil {
                group.message(Field.denseNodes) { dense in
                    dense.bytesField(Field.denseID, packedZigzag(deltas(nodes.map(\.id))))
                    dense.bytesField(Field.denseLat, packedZigzag(deltas(nodes.map(\.lat))))
                    dense.bytesField(Field.denseLon, packedZigzag(deltas(nodes.map(\.lon))))
                    if let rawKeysVals {
                        dense.bytesField(Field.denseKeysVals, packedPlain(rawKeysVals))
                    } else if nodes.contains(where: { !$0.tags.isEmpty }) {
                        var flat: [Int64] = []
                        for node in nodes {
                            for (k, v) in node.tags { flat.append(Int64(k)); flat.append(Int64(v)) }
                            flat.append(0)
                        }
                        dense.bytesField(Field.denseKeysVals, packedPlain(flat))
                    }
                }
            }
            for way in ways {
                group.message(Field.ways) { out in
                    out.varintField(Field.wayID, way.id)
                    if !way.tags.isEmpty {
                        out.bytesField(Field.wayKeys, packedPlain(way.tags.map { Int64($0.0) }))
                        out.bytesField(Field.wayVals, packedPlain(way.tags.map { Int64($0.1) }))
                    }
                    out.bytesField(Field.wayRefs, packedZigzag(deltas(way.refs)))
                }
            }
            for i in 0..<relations {
                group.message(Field.relations) { out in out.varintField(1, Int64(i + 1)) }
            }
        }
        return w.bytes
    }

    private func deltas(_ values: [Int64]) -> [Int64] {
        var out: [Int64] = []
        var previous: Int64 = 0
        for value in values {
            out.append(value &- previous)
            previous = value
        }
        return out
    }

    private func packedZigzag(_ values: [Int64]) -> [UInt8] {
        var w = ProtoWriter()
        for value in values { w.zigzag(value) }
        return w.bytes
    }

    private func packedPlain(_ values: [Int64]) -> [UInt8] {
        var w = ProtoWriter()
        for value in values { w.varint(UInt64(bitPattern: value)) }
        return w.bytes
    }

    private func decode(_ bytes: [UInt8]) -> Block {
        var storage = bytes
        // A block the test itself built: it decodes, or the test fixture is wrong.
        return try! storage.withUnsafeMutableBytes { raw in
            try Block(UnsafeRawBufferPointer(raw))
        }
    }

    // MARK: Nodes

    func testAnEmptyBlockHoldsNothing() {
        let b = decode(block())
        XCTAssertFalse(b.hasNodes)
        XCTAssertFalse(b.hasWays)
        XCTAssertFalse(b.hasRelations)
    }

    func testDenseNodesComeBackWithTheirIDsAndPlaces() {
        // Ids and coordinates are stored as deltas; three nodes is enough to catch a
        // decoder that forgets to accumulate.
        let b = decode(block(nodes: [
            DenseNode(id: 1, lat: 445_000_000, lon: 335_000_000),
            DenseNode(id: 2, lat: 445_000_100, lon: 335_000_200),
            DenseNode(id: 1000, lat: 444_000_000, lon: 336_000_000),
        ]))
        XCTAssertEqual(b.nodeIDs, [1, 2, 1000])
        XCTAssertEqual(b.nodeLat[0], 44.5, accuracy: 1e-9)
        XCTAssertEqual(b.nodeLon[0], 33.5, accuracy: 1e-9)
        // +100 units at the default granularity of 100 is 10^-5 of a degree.
        XCTAssertEqual(b.nodeLat[1], 44.50001, accuracy: 1e-9)
        XCTAssertEqual(b.nodeLon[1], 33.50002, accuracy: 1e-9)
        XCTAssertEqual(b.nodeLat[2], 44.4, accuracy: 1e-9)
        XCTAssertEqual(b.nodeLon[2], 33.6, accuracy: 1e-9)
    }

    func testNegativeCoordinatesSurviveTheDeltaChain() {
        // The southern and western hemispheres, and a crossing of the equator.
        let b = decode(block(nodes: [
            DenseNode(id: 1, lat: -337_000_000, lon: -700_000_000),
            DenseNode(id: 2, lat: 10_000_000, lon: -1_100_000_000),
        ]))
        XCTAssertEqual(b.nodeLat[0], -33.7, accuracy: 1e-9)
        XCTAssertEqual(b.nodeLon[0], -70.0, accuracy: 1e-9)
        XCTAssertEqual(b.nodeLat[1], 1.0, accuracy: 1e-9)
        XCTAssertEqual(b.nodeLon[1], -110.0, accuracy: 1e-9)
    }

    func testGranularityAndOffsetsAreApplied() {
        // A block may store coarser coordinates and shift them; both are honoured.
        let b = decode(block(granularity: 1000, latOffset: 1_000_000_000,
                             lonOffset: -2_000_000_000,
                             nodes: [DenseNode(id: 1, lat: 44_500_000, lon: 33_500_000)]))
        XCTAssertEqual(b.nodeLat[0], 45.5, accuracy: 1e-9)
        XCTAssertEqual(b.nodeLon[0], 31.5, accuracy: 1e-9)
    }

    func testNodeTagsPairUpAndStopAtTheirTerminator() {
        let strings = ["", "highway", "crossing", "barrier", "gate", "name", "Zoll"]
        let b = decode(block(strings: strings, nodes: [
            DenseNode(id: 1, lat: 0, lon: 0, tags: [(1, 2)]),
            DenseNode(id: 2, lat: 0, lon: 0, tags: []),
            DenseNode(id: 3, lat: 0, lon: 0, tags: [(3, 4), (5, 6)]),
        ]))
        XCTAssertEqual(b.nodeTags[0].map(\.0), ["highway"])
        XCTAssertEqual(b.nodeTags[0].map(\.1), ["crossing"])
        XCTAssertTrue(b.nodeTags[1].isEmpty)
        XCTAssertEqual(b.nodeTags[2].map(\.0), ["barrier", "name"])
        XCTAssertEqual(b.nodeTags[2].map(\.1), ["gate", "Zoll"])
    }

    func testABlockWithNoTagListAtAllLeavesEveryNodeUntagged() {
        let b = decode(block(nodes: [
            DenseNode(id: 1, lat: 0, lon: 0),
            DenseNode(id: 2, lat: 0, lon: 0),
        ]))
        XCTAssertEqual(b.nodeTags.count, 2)
        XCTAssertTrue(b.nodeTags.allSatisfy(\.isEmpty))
    }

    func testFewerCoordinatesThanIDsDoesNotLoseTheNodes() {
        // Truncated arrays: the ids run on past the coordinates. Every node must still
        // appear, because a caller indexes the three arrays together.
        var bytes = ProtoWriter()
        bytes.message(Field.stringTable) { $0.stringField(Field.stringEntry, "") }
        bytes.message(Field.primitiveGroup) { group in
            group.message(Field.denseNodes) { dense in
                dense.bytesField(Field.denseID, packedZigzag([1, 1, 1]))
                dense.bytesField(Field.denseLat, packedZigzag([100]))
                dense.bytesField(Field.denseLon, packedZigzag([100]))
            }
        }
        let b = decode(bytes.bytes)
        XCTAssertEqual(b.nodeIDs.count, 3)
        XCTAssertEqual(b.nodeLat.count, 3)
        XCTAssertEqual(b.nodeLon.count, 3)
    }

    // MARK: Ways

    func testWaysKeepTheirRefsInOrder() {
        let b = decode(block(ways: [RawWay(id: 42, refs: [10, 11, 12, 500, 11])]))
        XCTAssertEqual(b.wayIDs, [42])
        XCTAssertEqual(b.wayRefs[0], [10, 11, 12, 500, 11])
    }

    func testWayRefDeltasMayGoBackwards() {
        // A way that doubles back has descending refs, stored as negative deltas.
        let b = decode(block(ways: [RawWay(id: 1, refs: [1000, 200, 1000])]))
        XCTAssertEqual(b.wayRefs[0], [1000, 200, 1000])
    }

    func testWayTagsPairKeysWithValues() {
        let strings = ["", "highway", "track", "surface", "gravel"]
        let b = decode(block(strings: strings,
                             ways: [RawWay(id: 7, refs: [1, 2], tags: [(1, 2), (3, 4)])]))
        XCTAssertEqual(b.wayTags[0].map(\.0), ["highway", "surface"])
        XCTAssertEqual(b.wayTags[0].map(\.1), ["track", "gravel"])
    }

    func testAWayWithNoRefsIsStillReported() {
        let b = decode(block(ways: [RawWay(id: 9, refs: [])]))
        XCTAssertEqual(b.wayIDs, [9])
        XCTAssertEqual(b.wayRefs[0], [])
    }

    func testRelationsAreNoticedButNotDecoded() {
        let b = decode(block(relations: 3))
        XCTAssertTrue(b.hasRelations)
        XCTAssertFalse(b.hasNodes)
        XCTAssertFalse(b.hasWays)
    }

    func testNodesAndWaysCanShareABlock() {
        let b = decode(block(nodes: [DenseNode(id: 1, lat: 0, lon: 0)],
                             ways: [RawWay(id: 2, refs: [1])]))
        XCTAssertTrue(b.hasNodes)
        XCTAssertTrue(b.hasWays)
    }

    // MARK: Blocks no honest tool would write

    func testAStringIndexPastTheTableReadsAsEmptyRatherThanCrashing() {
        let b = decode(block(strings: ["", "highway"],
                             nodes: [DenseNode(id: 1, lat: 0, lon: 0, tags: [(99, 100)])],
                             ways: [RawWay(id: 2, refs: [1], tags: [(70, 80)])]))
        XCTAssertEqual(b.nodeTags[0].map(\.0), [""])
        XCTAssertEqual(b.wayTags[0].map(\.0), [""])
    }

    func testAStringIndexTooLargeForAnInt32DoesNotCrash() {
        // The index is a varint, so nothing stops it being 2^40.
        let b = decode(block(strings: ["", "highway"],
                             nodes: [DenseNode(id: 1, lat: 0, lon: 0)],
                             rawKeysVals: [1 << 40, 1, 0]))
        XCTAssertEqual(b.nodeIDs.count, 1)
    }

    func testAGranularityPastAnInt64DoesNotCrash() {
        // granularity is an int32 in the schema, but nothing on the wire enforces that.
        var bytes = ProtoWriter()
        bytes.message(Field.stringTable) { $0.stringField(Field.stringEntry, "") }
        bytes.key(Field.granularity, Wire.varint)
        bytes.varint(UInt64.max)
        bytes.message(Field.primitiveGroup) { group in
            group.message(Field.denseNodes) { dense in
                dense.bytesField(Field.denseID, packedZigzag([1]))
                dense.bytesField(Field.denseLat, packedZigzag([1]))
                dense.bytesField(Field.denseLon, packedZigzag([1]))
            }
        }
        let b = decode(bytes.bytes)
        XCTAssertEqual(b.nodeIDs, [1])
    }

    func testCoordinatesThatOverflowAnInt64DoNotCrash() {
        // Granularity times delta, where both are near the top of the range.
        let b = decode(block(granularity: 1 << 40,
                             nodes: [DenseNode(id: 1, lat: Int64.max / 2, lon: Int64.max / 2)]))
        XCTAssertEqual(b.nodeIDs, [1])
    }

    func testATagListThatStopsMidPairLosesOnlyTheHalfPair() {
        // Two nodes, and the list ends after the first node's terminator and one stray key.
        let b = decode(block(strings: ["", "a", "b"],
                             nodes: [DenseNode(id: 1, lat: 0, lon: 0),
                                     DenseNode(id: 2, lat: 0, lon: 0)],
                             rawKeysVals: [1, 2, 0, 1]))
        XCTAssertEqual(b.nodeTags.count, 2)
        XCTAssertEqual(b.nodeTags[0].map(\.0), ["a"])
        XCTAssertTrue(b.nodeTags[1].isEmpty)
    }

    func testTruncatedBytesDoNotCrashTheDecoder() {
        // Every prefix of a real block. None of them may take the process down.
        let full = block(strings: ["", "highway", "track"],
                         nodes: [DenseNode(id: 1, lat: 100, lon: 200, tags: [(1, 2)])],
                         ways: [RawWay(id: 2, refs: [1, 2, 3], tags: [(1, 2)])],
                         relations: 1)
        for length in 0..<full.count {
            let b = decode(Array(full.prefix(length)))
            XCTAssertLessThanOrEqual(b.nodeIDs.count, 1, "prefix of \(length)")
        }
    }

    // MARK: What the rewriter asks a block

    func testUsesAnyFindsAWayThatNamesAMergedNode() {
        let b = decode(block(ways: [RawWay(id: 1, refs: [10, 20, 30])]))
        XCTAssertTrue(b.usesAny(of: [20: 21], filter: IDFilter([20])))
        XCTAssertFalse(b.usesAny(of: [99: 1], filter: IDFilter([99])))
        XCTAssertFalse(b.usesAny(of: [:], filter: IDFilter()))
        // The filter only saves a lookup; it never decides the answer.
        XCTAssertTrue(b.usesAny(of: [20: 21], filter: IDFilter([10, 20, 30, 40])))
    }

    func testMovedNodesTakeTheirNewPlaceAndTheRestKeepTheirs() {
        let b = decode(block(nodes: [
            DenseNode(id: 1, lat: 445_000_000, lon: 335_000_000),
            DenseNode(id: 2, lat: 445_000_000, lon: 335_000_000),
        ]))
        let moved = b.nodes(movedBy: [2: (lat: 10.0, lon: 20.0)], filter: IDFilter([2]))
        XCTAssertEqual(moved[0].lat, 44.5, accuracy: 1e-9)
        XCTAssertEqual(moved[1].lat, 10.0)
        XCTAssertEqual(moved[1].lon, 20.0)
    }

    func testAMergedNodeGivesUpItsIDEverywhereInAWay() {
        let b = decode(block(ways: [RawWay(id: 1, refs: [10, 20, 10])]))
        let ways = b.ways(inserting: [:], merging: [10: 99])
        XCTAssertEqual(ways[0].refs, [99, 20, 99])
    }

    func testInsertsLandAfterTheirSegmentAndKeepTheWayRunningTheSameWayRound() {
        let b = decode(block(ways: [RawWay(id: 1, refs: [10, 20, 30])]))
        // Furthest along first within a segment, as the rewriter sorts them.
        let ways = b.ways(inserting: [1: [(after: 20, segment: 1, along: 0.5, node: 500),
                                          (after: 10, segment: 0, along: 0.7, node: 401),
                                          (after: 10, segment: 0, along: 0.3, node: 400)]],
                          merging: [:])
        XCTAssertEqual(ways[0].refs, [10, 400, 401, 20, 500, 30])
    }

    /// The planner sees a way with the nodes the extract lacks cut out, so a position
    /// counted there is not a position in the way as the file has it.
    func testAnInsertFindsItsSegmentByNodeInAWayTheExtractCutShort() {
        // The file has [10, 20, 30]; node 10 is outside the extract, so the planner saw
        // [20, 30] and its segment 0 starts at node 20.
        let b = decode(block(ways: [RawWay(id: 1, refs: [10, 20, 30])]))
        let ways = b.ways(inserting: [1: [(after: 20, segment: 0, along: 0.5, node: 500)]],
                          merging: [:])
        XCTAssertEqual(ways[0].refs, [10, 20, 500, 30], "after 20, not at position 1")
    }

    func testAnInsertAfterAMergedNodeFollowsTheMerge() {
        let b = decode(block(ways: [RawWay(id: 1, refs: [10, 20, 30])]))
        let ways = b.ways(inserting: [1: [(after: 20, segment: 1, along: 0.5, node: 500)]],
                          merging: [20: 99])
        XCTAssertEqual(ways[0].refs, [10, 99, 500, 30])
    }

    func testAClosedWayInsertsAfterTheCopyTheSegmentStartedFrom() {
        // First and last are the same node; the last segment starts at its second copy.
        let b = decode(block(ways: [RawWay(id: 1, refs: [10, 20, 30, 10])]))
        let ways = b.ways(inserting: [1: [(after: 10, segment: 0, along: 0.5, node: 400),
                                          (after: 30, segment: 2, along: 0.5, node: 500)]],
                          merging: [:])
        XCTAssertEqual(ways[0].refs, [10, 400, 20, 30, 500, 10])
    }

    func testAnInsertAfterANodeTheWayDoesNotHoldIsIgnoredRatherThanCrashing() {
        let b = decode(block(ways: [RawWay(id: 1, refs: [10, 20])]))
        let ways = b.ways(inserting: [1: [(after: 99, segment: 5, along: 0.5, node: 500)]],
                          merging: [:])
        XCTAssertEqual(ways[0].refs, [10, 20])
    }
}
