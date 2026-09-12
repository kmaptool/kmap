import XCTest
@testable import kmap

/// Reading a PBF: blobs off the file, blocks out of the blobs, elements out of the blocks.
///
/// Several tests build the file by hand, blob framing and all, so a block can be malformed
/// in one particular way. Malformed input is refused or read, never fatal.
final class PBFReaderTests: XCTestCase {

    private var directory = URL(fileURLWithPath: "/tmp")

    override func setUpWithError() throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("kmap-reader-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func path(_ name: String = "in.osm.pbf") -> URL {
        directory.appendingPathComponent(name)
    }

    private struct Collected: OSMSink {
        var nodes: [(id: Int64, lat: Double, lon: Double, tags: [(String, String)])] = []
        var ways: [(id: Int64, refs: [Int64], tags: [(String, String)])] = []
        var relations: [(id: Int64, kinds: [Int32], ids: [Int64], roles: [String])] = []

        mutating func node(id: Int64, lat: Double, lon: Double,
                           tags: ArraySlice<Int32>, block: OSMBlock) {
            var pairs: [(String, String)] = []
            var i = tags.startIndex
            while i + 1 < tags.endIndex {
                pairs.append((block.text(Int(tags[i])), block.text(Int(tags[i + 1]))))
                i += 2
            }
            nodes.append((id, lat, lon, pairs))
        }

        mutating func way(id: Int64, refs: ArraySlice<Int64>, keys: ArraySlice<Int32>,
                          values: ArraySlice<Int32>, block: OSMBlock) {
            ways.append((id, Array(refs),
                         zip(keys, values).map { (block.text(Int($0)), block.text(Int($1))) }))
        }

        mutating func relation(id: Int64, memberKinds: ArraySlice<Int32>,
                               memberIDs: ArraySlice<Int64>, memberRoles: ArraySlice<Int32>,
                               keys: ArraySlice<Int32>, values: ArraySlice<Int32>,
                               block: OSMBlock) {
            relations.append((id, Array(memberKinds), Array(memberIDs),
                              memberRoles.map { block.text(Int($0)) }))
        }
    }

    @discardableResult
    private func read(_ url: URL) throws -> Collected {
        var collected = Collected()
        try PBFReader(url: url).read(into: &collected)
        return collected
    }

    // MARK: Building a file by hand

    /// A blob carrying its payload uncompressed, as the format allows.
    private func rawBlob(kind: String, payload: [UInt8]) -> [UInt8] {
        var blob = ProtoWriter()
        blob.bytesField(1, payload)                    // raw
        var header = ProtoWriter()
        header.stringField(1, kind)
        header.varintField(3, Int64(blob.bytes.count))
        return framed(header: header.bytes) + blob.bytes
    }

    private func framed(header: [UInt8]) -> [UInt8] {
        var big = UInt32(header.count).bigEndian
        var out: [UInt8] = []
        withUnsafeBytes(of: &big) { out.append(contentsOf: $0) }
        return out + header
    }

    /// A PrimitiveBlock with one dense node whose tag run is given verbatim.
    private func blockWithDenseTags(_ keysVals: [Int64], strings: [String]) -> [UInt8] {
        var w = ProtoWriter()
        w.message(1) { table in
            for s in strings { table.stringField(1, s) }
        }
        w.message(2) { group in
            group.message(2) { dense in
                var ids = ProtoWriter(); ids.zigzag(1)
                var lats = ProtoWriter(); lats.zigzag(0)
                var lons = ProtoWriter(); lons.zigzag(0)
                var tags = ProtoWriter()
                for value in keysVals { tags.varint(UInt64(bitPattern: value)) }
                dense.bytesField(1, ids.bytes)
                dense.bytesField(8, lats.bytes)
                dense.bytesField(9, lons.bytes)
                dense.bytesField(10, tags.bytes)
            }
        }
        return w.bytes
    }

    private func write(_ bytes: [UInt8], to url: URL) throws {
        try Data(bytes).write(to: url)
    }

    // MARK: The ordinary path

    func testEveryElementOfAWrittenFileComesBack() throws {
        let url = path()
        let writer = try PBFWriter(to: url)
        writer.header()
        writer.nodes([
            PBFWriter.Node(id: 1, lat: 44.5, lon: 33.5, tags: [("barrier", "gate")]),
            PBFWriter.Node(id: 2, lat: 44.6, lon: 33.6, tags: []),
        ])
        writer.ways([PBFWriter.Way(id: 10, refs: [1, 2], tags: [("highway", "track")])])
        writer.relations([PBFWriter.Relation(
            id: 20, members: [.init(kind: 1, ref: 10, role: "outer")],
            tags: [("type", "multipolygon")])])
        try writer.finish()

        let out = try read(url)
        XCTAssertEqual(out.nodes.map(\.id), [1, 2])
        XCTAssertEqual(out.nodes[0].tags.map(\.1), ["gate"])
        XCTAssertEqual(out.ways.map(\.id), [10])
        XCTAssertEqual(out.ways[0].refs, [1, 2])
        XCTAssertEqual(out.relations.map(\.id), [20])
        XCTAssertEqual(out.relations[0].roles, ["outer"])
    }

    func testAnUncompressedBlobIsReadAsHappilyAsACompressedOne() throws {
        let url = path("raw.osm.pbf")
        var file = rawBlob(kind: "OSMHeader", payload: [])
        file += rawBlob(kind: "OSMData",
                        payload: blockWithDenseTags([1, 2, 0], strings: ["", "a", "b"]))
        try write(file, to: url)

        let out = try read(url)
        XCTAssertEqual(out.nodes.map(\.id), [1])
        XCTAssertEqual(out.nodes[0].tags.map(\.0), ["a"])
    }

    func testBlocksAreHandedOverInFileOrder() throws {
        // Ids ascend across four blocks, so blocks delivered out of order show up here.
        let url = path("ordered.osm.pbf")
        let writer = try PBFWriter(to: url)
        writer.header()
        for batch in 0..<4 {
            writer.nodes((0..<1000).map {
                PBFWriter.Node(id: Int64(batch * 1000 + $0 + 1), lat: 0, lon: 0, tags: [])
            })
        }
        try writer.finish()
        let out = try read(url)
        XCTAssertEqual(out.nodes.map(\.id), Array(1...4000))
    }

    func testManyBlocksSurviveTheWholeWayRound() throws {
        // Past any batching the reader does inside, with tags so the string tables differ.
        let url = path("many.osm.pbf")
        let writer = try PBFWriter(to: url)
        writer.header()
        for batch in 0..<40 {
            writer.nodes((0..<2000).map { i in
                PBFWriter.Node(id: Int64(batch * 2000 + i + 1), lat: 45, lon: 33,
                               tags: [("block", "\(batch)")])
            })
        }
        try writer.finish()
        let out = try read(url)
        XCTAssertEqual(out.nodes.count, 80_000)
        XCTAssertEqual(out.nodes[0].tags.map(\.1), ["0"])
        XCTAssertEqual(out.nodes[79_999].tags.map(\.1), ["39"])
    }

    func testTheHeaderBoundingBoxIsReadBackAsWritten() throws {
        let url = path("bbox.osm.pbf")
        let writer = try PBFWriter(to: url)
        writer.header(bbox: (minLat: -33.9, minLon: 18.4, maxLat: -33.8, maxLon: 18.5))
        try writer.finish()
        let box = try PBFReader(url: url).headerBBox()
        XCTAssertEqual(box?.minLat ?? 0, -33.9, accuracy: 1e-9)
        XCTAssertEqual(box?.maxLon ?? 0, 18.5, accuracy: 1e-9)
    }

    func testAFileWithNoBoundingBoxSaysSoRatherThanGuessing() throws {
        let url = path("nobbox.osm.pbf")
        let writer = try PBFWriter(to: url)
        writer.header()
        try writer.finish()
        XCTAssertNil(try PBFReader(url: url).headerBBox())
    }

    /// A header without a box is not the end of it: the nodes carry the same answer.
    func testTheBoxIsMeasuredFromTheNodesWhereTheHeaderCarriesNone() throws {
        let url = path("measured.osm.pbf")
        let writer = try PBFWriter(to: url)
        writer.header()
        writer.nodes([
            PBFWriter.Node(id: 1, lat: 44.5, lon: 33.5, tags: []),
            PBFWriter.Node(id: 2, lat: 44.7, lon: 33.9, tags: []),
            PBFWriter.Node(id: 3, lat: 44.6, lon: 33.1, tags: []),
        ])
        // A way names nodes it does not carry: its place comes from them.
        writer.ways([PBFWriter.Way(id: 10, refs: [1, 2, 3], tags: [("highway", "track")])])
        try writer.finish()

        let box = try XCTUnwrap(try PBFReader(url: url).nodeBounds())
        XCTAssertEqual(box.minLat, 44.5, accuracy: 1e-6)
        XCTAssertEqual(box.maxLat, 44.7, accuracy: 1e-6)
        XCTAssertEqual(box.minLon, 33.1, accuracy: 1e-6)
        XCTAssertEqual(box.maxLon, 33.9, accuracy: 1e-6)
    }

    /// An extract with no node covers no ground, which is not the same as an unknown one.
    func testAFileWithNoNodesMeasuresNoBox() throws {
        let url = path("nonodes.osm.pbf")
        let writer = try PBFWriter(to: url)
        writer.header()
        try writer.finish()
        XCTAssertNil(try PBFReader(url: url).nodeBounds())
    }

    // MARK: Files that are wrong

    func testAnEmptyFileReadsAsEmpty() throws {
        let url = path("empty.osm.pbf")
        try write([], to: url)
        let out = try read(url)
        XCTAssertTrue(out.nodes.isEmpty)
    }

    func testAFileCutOffMidBlobIsRefusedNotGuessedAt() throws {
        let url = path("cut.osm.pbf")
        var file = rawBlob(kind: "OSMHeader", payload: [])
        file += rawBlob(kind: "OSMData",
                        payload: blockWithDenseTags([1, 2, 0], strings: ["", "a", "b"]))
        try write(Array(file.dropLast(20)), to: url)
        XCTAssertThrowsError(try read(url))
    }

    func testEveryTruncationOfARealFileEitherReadsOrThrows() throws {
        // Twenty cut lengths across a whole file; none of them may crash the reader.
        let source = path("full.osm.pbf")
        let writer = try PBFWriter(to: source)
        writer.header()
        writer.nodes((1...500).map {
            PBFWriter.Node(id: Int64($0), lat: 45, lon: 33, tags: [("name", "n\($0)")])
        })
        writer.ways([PBFWriter.Way(id: 1, refs: Array(1...500), tags: [])])
        try writer.finish()

        let whole = try Data(contentsOf: source)
        for cut in stride(from: 0, to: whole.count, by: max(1, whole.count / 20)) {
            let url = path("cut-\(cut).osm.pbf")
            try whole.prefix(cut).write(to: url)
            _ = try? read(url)
        }
    }

    func testABlobHeaderLengthPastTheEndOfTheFileIsRefused() throws {
        let url = path("longheader.osm.pbf")
        try write([0x7F, 0xFF, 0xFF, 0xFF, 1, 2, 3], to: url)
        XCTAssertThrowsError(try read(url))
    }

    func testAPayloadClaimingToInflateToATerabyteIsRefused() throws {
        // raw_size is a number in the file. Believing it means asking for the memory.
        let url = path("huge.osm.pbf")
        var blob = ProtoWriter()
        blob.varintField(2, 1 << 40)                  // raw_size
        blob.bytesField(3, [0x78, 0x9C, 0x03, 0x00])  // an empty zlib stream
        var header = ProtoWriter()
        header.stringField(1, "OSMData")
        header.varintField(3, Int64(blob.bytes.count))
        try write(framed(header: header.bytes) + blob.bytes, to: url)
        XCTAssertThrowsError(try read(url))
    }

    func testABlobCompressedInAWayThisReaderDoesNotDoIsNamedInTheError() throws {
        for (field, name) in [(4, "lzma"), (6, "lz4"), (7, "zstd")] {
            let url = path("\(name).osm.pbf")
            var blob = ProtoWriter()
            blob.varintField(2, 100)
            blob.bytesField(field, [1, 2, 3])
            var header = ProtoWriter()
            header.stringField(1, "OSMData")
            header.varintField(3, Int64(blob.bytes.count))
            try write(framed(header: header.bytes) + blob.bytes, to: url)
            XCTAssertThrowsError(try read(url)) { error in
                XCTAssertTrue("\(error)".contains(name), "\(error)")
            }
        }
    }

    func testAZlibFieldTooShortToHoldItsOwnHeaderIsRefused() throws {
        let url = path("stub.osm.pbf")
        var blob = ProtoWriter()
        blob.varintField(2, 100)
        blob.bytesField(3, [0x78])                    // one byte of a two-byte header
        var header = ProtoWriter()
        header.stringField(1, "OSMData")
        header.varintField(3, Int64(blob.bytes.count))
        try write(framed(header: header.bytes) + blob.bytes, to: url)
        XCTAssertThrowsError(try read(url))
    }

    func testADenseTagRunThatEndsMidPairDoesNotCrash() throws {
        // The run ends on a key with no value and no terminator; the node comes back with
        // whatever is there.
        let url = path("oddtags.osm.pbf")
        var file = rawBlob(kind: "OSMHeader", payload: [])
        file += rawBlob(kind: "OSMData",
                        payload: blockWithDenseTags([1], strings: ["", "a"]))
        try write(file, to: url)
        let out = try read(url)
        XCTAssertEqual(out.nodes.map(\.id), [1])
    }

    func testADenseTagRunWithNoTerminatorAtAllDoesNotCrash() throws {
        let url = path("noterm.osm.pbf")
        var file = rawBlob(kind: "OSMHeader", payload: [])
        file += rawBlob(kind: "OSMData",
                        payload: blockWithDenseTags([1, 2], strings: ["", "a", "b"]))
        try write(file, to: url)
        let out = try read(url)
        XCTAssertEqual(out.nodes.map(\.id), [1])
        XCTAssertEqual(out.nodes[0].tags.map(\.0), ["a"])
    }

    func testAGranularityPastAnInt64DoesNotCrashTheReader() throws {
        let url = path("granularity.osm.pbf")
        var block = ProtoWriter()
        block.message(1) { $0.stringField(1, "") }
        block.key(17, Wire.varint)
        block.varint(UInt64.max)
        block.message(2) { group in
            group.message(2) { dense in
                var ids = ProtoWriter(); ids.zigzag(1)
                var lats = ProtoWriter(); lats.zigzag(1)
                var lons = ProtoWriter(); lons.zigzag(1)
                dense.bytesField(1, ids.bytes)
                dense.bytesField(8, lats.bytes)
                dense.bytesField(9, lons.bytes)
            }
        }
        var file = rawBlob(kind: "OSMHeader", payload: [])
        file += rawBlob(kind: "OSMData", payload: block.bytes)
        try write(file, to: url)
        let out = try read(url)
        XCTAssertEqual(out.nodes.map(\.id), [1])
    }

    func testAStringIndexPastTheTableReadsAsEmpty() throws {
        let url = path("badindex.osm.pbf")
        var file = rawBlob(kind: "OSMHeader", payload: [])
        file += rawBlob(kind: "OSMData",
                        payload: blockWithDenseTags([50, 60, 0], strings: ["", "a"]))
        try write(file, to: url)
        let out = try read(url)
        XCTAssertEqual(out.nodes[0].tags.map(\.0), [""])
    }

    // MARK: Granularity and offsets

    func testCoordinatesHonourGranularityAndOffset() throws {
        let url = path("granular.osm.pbf")
        var block = ProtoWriter()
        block.message(1) { $0.stringField(1, "") }
        block.varintField(17, 1000)                 // granularity
        block.varintField(19, 1_000_000_000)        // lat offset, nanodegrees
        block.message(2) { group in
            group.message(2) { dense in
                var ids = ProtoWriter(); ids.zigzag(1)
                var lats = ProtoWriter(); lats.zigzag(44_000_000)
                var lons = ProtoWriter(); lons.zigzag(33_000_000)
                dense.bytesField(1, ids.bytes)
                dense.bytesField(8, lats.bytes)
                dense.bytesField(9, lons.bytes)
            }
        }
        var file = rawBlob(kind: "OSMHeader", payload: [])
        file += rawBlob(kind: "OSMData", payload: block.bytes)
        try write(file, to: url)

        let out = try read(url)
        XCTAssertEqual(out.nodes[0].lat, 45.0, accuracy: 1e-9)
        XCTAssertEqual(out.nodes[0].lon, 33.0, accuracy: 1e-9)
    }

    // MARK: Stopping

    /// Three blobs of one node each; enough to stop between.
    private func threeBlobs() throws -> URL {
        let url = path("three.osm.pbf")
        var bytes: [UInt8] = []
        for _ in 0..<3 { bytes += rawBlob(kind: "OSMData", payload: blockWithDenseTags([0], strings: [""])) }
        try write(bytes, to: url)
        return url
    }

    func testAReaderToldToStopReadsNothing() throws {
        let url = try threeBlobs()
        var reader = PBFReader(url: url)
        reader.shouldStop = { true }
        var collected = Collected()
        XCTAssertThrowsError(try reader.read(into: &collected)) { XCTAssertTrue($0 is CancellationError) }
        XCTAssertTrue(collected.nodes.isEmpty, "nothing was decoded")
        XCTAssertThrowsError(try reader.readInOrder(make: { Collected() }, apply: { _ in })) {
            XCTAssertTrue($0 is CancellationError)
        }
        XCTAssertThrowsError(try reader.readConcurrently(workers: 2, make: { Collected() })) {
            XCTAssertTrue($0 is CancellationError)
        }
    }

    func testTheStopIsAskedBetweenBlobsNotOnceAtTheStart() throws {
        let url = try threeBlobs()
        var asked = 0
        var reader = PBFReader(url: url)
        reader.shouldStop = { asked += 1; return asked > 1 }
        var collected = Collected()
        XCTAssertThrowsError(try reader.read(into: &collected))
        XCTAssertEqual(asked, 2, "the first blob went through, the second was refused")
    }

    func testACancelledTaskStopsTheReadOnItsOwn() async throws {
        let url = try threeBlobs()
        let task = Task<Int, Error> {
            // Held until the cancel has landed, so the read starts in a cancelled task.
            while !Task.isCancelled { await Task.yield() }
            var collected = Collected()
            try PBFReader(url: url).read(into: &collected)
            return collected.nodes.count
        }
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("a cancelled task reads nothing")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
    }
}
