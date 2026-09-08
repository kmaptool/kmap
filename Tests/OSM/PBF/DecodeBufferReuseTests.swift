import XCTest
@testable import kmap

/// The decoder's buffers are refilled, not replaced.
///
/// A slice handed to the sink points into the buffer it was filled from, so a reused
/// buffer keeps its address. Distinct addresses are counted, since growth moves a buffer.
final class DecodeBufferReuseTests: XCTestCase {

    private var folder: URL!

    override func setUpWithError() throws {
        folder = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("reuse-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: self.folder) }
    }

    /// Records where each element's slices were stored, not what was in them.
    private struct Addresses: OSMSink {
        var wayRefs = Set<UInt>(), wayKeys = Set<UInt>()
        /// Where each node's tags began and how many there were, in file order.
        var nodeTags: [(at: UInt, count: Int)] = []
        var ways = 0, nodes = 0

        private static func address<T>(_ slice: ArraySlice<T>) -> UInt? {
            slice.withUnsafeBufferPointer { $0.baseAddress.map { UInt(bitPattern: $0) } }
        }

        mutating func node(id: Int64, lat: Double, lon: Double,
                           tags: ArraySlice<Int32>, block: OSMBlock) {
            nodes += 1
            if let at = Self.address(tags) { nodeTags.append((at, tags.count)) }
        }

        mutating func way(id: Int64, refs: ArraySlice<Int64>, keys: ArraySlice<Int32>,
                          values: ArraySlice<Int32>, block: OSMBlock) {
            ways += 1
            if let at = Self.address(refs) { wayRefs.insert(at) }
            if let at = Self.address(keys) { wayKeys.insert(at) }
        }

        mutating func relation(id: Int64, memberKinds: ArraySlice<Int32>,
                               memberIDs: ArraySlice<Int64>, memberRoles: ArraySlice<Int32>,
                               keys: ArraySlice<Int32>, values: ArraySlice<Int32>,
                               block: OSMBlock) {}
    }

    private func fileWithManyWays(_ count: Int) throws -> URL {
        let url = folder.appendingPathComponent("ways.osm.pbf")
        let writer = try PBFWriter(to: url)
        writer.header()
        var batch: [PBFWriter.Way] = []
        for id in 1...count {
            batch.append(PBFWriter.Way(id: Int64(id),
                                       refs: (0..<8).map { Int64(id * 10 + $0) },
                                       tags: [("highway", "path"), ("name", "way \(id)")]))
        }
        writer.ways(batch)
        try writer.finish()
        return url
    }

    /// The helpers append into the buffer they are given and never hand back a new one:
    /// a replacement resets capacity to the count, a refill does not.
    func testTheHelpersAppendIntoTheBufferTheyAreGiven() {
        var out = [Int32]()
        out.reserveCapacity(4096)
        let capacity = out.capacity
        let bytes: [UInt8] = [0x01, 0x02, 0x03, 0x04, 0x05]

        bytes.withUnsafeBytes { PBFReader.packedVarint32($0, into: &out) }
        XCTAssertEqual(out, [1, 2, 3, 4, 5])
        XCTAssertEqual(out.capacity, capacity, "a fill must not move the buffer")

        // Appends rather than replaces: what was there is still there in front.
        bytes.withUnsafeBytes { PBFReader.packedVarint32($0, into: &out) }
        XCTAssertEqual(out, [1, 2, 3, 4, 5, 1, 2, 3, 4, 5])
        XCTAssertEqual(out.capacity, capacity)

        var wide = [Int64]()
        wide.reserveCapacity(4096)
        let wideCapacity = wide.capacity
        // Zigzag: 2 is 1, 4 is 2, 1 is -1.
        let zigzagged: [UInt8] = [0x02, 0x04, 0x01]
        zigzagged.withUnsafeBytes { PBFReader.packedZigzag($0, into: &wide) }
        XCTAssertEqual(wide, [1, 2, -1])
        XCTAssertEqual(wide.capacity, wideCapacity)
    }

    /// Catches the scattered case only: an allocator may hand back the same address for a
    /// replacement of the same size. The dense test below pins the arithmetic down.
    func testAWayDoesNotGetAFreshBufferEveryTime() throws {
        let url = try fileWithManyWays(2000)
        var seen = Addresses()
        try PBFReader(url: url).read(into: &seen)

        XCTAssertEqual(seen.ways, 2000)
        // A handful of addresses means the buffer grew a few times early and then settled.
        // One per way -- which is what assigning a new array gives -- would be thousands.
        XCTAssertLessThan(seen.wayRefs.count, 8,
                          "way refs are landing in \(seen.wayRefs.count) different buffers")
        XCTAssertLessThan(seen.wayKeys.count, 8,
                          "way keys are landing in \(seen.wayKeys.count) different buffers")
    }

    /// Every dense node's tags are a slice of one buffer, so each begins at a different
    /// address. While the buffer is reused the slices run through it end to end, one
    /// place apart for the separator.
    func testDenseNodesShareOneBufferToo() throws {
        let url = folder.appendingPathComponent("nodes.osm.pbf")
        let writer = try PBFWriter(to: url)
        writer.header()
        writer.nodes((1...4000).map {
            PBFWriter.Node(id: Int64($0), lat: 44 + Double($0) / 100_000,
                           lon: 33 + Double($0) / 100_000,
                           tags: [("place", "hamlet")])
        })
        try writer.finish()

        var seen = Addresses()
        try PBFReader(url: url).read(into: &seen)
        XCTAssertEqual(seen.nodes, 4000)
        XCTAssertEqual(seen.nodeTags.count, 4000, "every node here carries a tag")

        var consecutive = 0
        for (previous, next) in zip(seen.nodeTags, seen.nodeTags.dropFirst()) {
            // Four bytes an entry, and one entry of separator between two nodes.
            let expected = previous.at + UInt((previous.count + 1) * MemoryLayout<Int32>.stride)
            if next.at == expected { consecutive += 1 }
        }
        // Not all of them: a block boundary starts the buffer over, and this file is
        // several blocks. Nearly all of them is what one buffer per block looks like.
        XCTAssertGreaterThan(consecutive, seen.nodeTags.count - 10,
                             "dense tags are not running end to end through one buffer")
    }
}
