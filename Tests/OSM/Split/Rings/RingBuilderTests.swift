import XCTest

@testable import kmap

/// Rings joined out of multipolygon members, against the plain scan that used to do it.
final class RingBuilderTests: XCTestCase {
    /// The assembly as it was written first: the last piece seeds a chain, and the
    /// lowest-numbered piece sharing an end joins on. The indexed version must agree on
    /// every input, including the direction and starting point of every ring.
    private static func plainRings(pieces input: [[Int64]]) -> (closed: [[Int64]], open: [[Int64]]) {
        var pieces = input.filter { $0.count >= 2 }
        var closedIDs: [[Int64]] = []
        var open: [[Int64]] = []
        while var chain = pieces.popLast() {
            var grew = true
            while grew {
                grew = false
                if chain.first == chain.last { break }
                for (index, piece) in pieces.enumerated() {
                    if piece.first == chain.last {
                        chain.append(contentsOf: piece.dropFirst())
                    } else if piece.last == chain.last {
                        chain.append(contentsOf: piece.reversed().dropFirst())
                    } else if piece.last == chain.first {
                        chain.insert(contentsOf: piece.dropLast(), at: 0)
                    } else if piece.first == chain.first {
                        chain.insert(contentsOf: piece.reversed().dropLast(), at: 0)
                    } else {
                        continue
                    }
                    pieces.remove(at: index)
                    grew = true
                    break
                }
            }
            if chain.first == chain.last && chain.count > 3 { closedIDs.append(chain) } else { open.append(chain) }
        }
        return (closedIDs, open)
    }

    /// Random rings cut into pieces, some reversed, all shuffled, plus a few loose ends.
    private func pieces(using random: inout SplitMix64) -> [[Int64]] {
        var out: [[Int64]] = []
        var next: Int64 = 1
        for _ in 0..<Int.random(in: 1...4, using: &random) {
            let count = Int.random(in: 3...40, using: &random)
            let ids = (0..<count).map { next + Int64($0) }
            next += Int64(count)
            let ring = ids + [ids[0]]
            var at = 0
            while at < ring.count - 1 {
                let length = Int.random(in: 1...6, using: &random)
                let end = min(ring.count - 1, at + length)
                var piece = Array(ring[at...end])
                if Bool.random(using: &random) { piece.reverse() }
                out.append(piece)
                at = end
            }
        }
        for _ in 0..<Int.random(in: 0...3, using: &random) {
            let count = Int.random(in: 2...5, using: &random)
            out.append((0..<count).map { next + Int64($0) })
            next += Int64(count)
        }
        return out.shuffled(using: &random)
    }

    func testTheIndexedAssemblyMatchesThePlainScanOnEveryRing() {
        var random = SplitMix64(state: 20_260_930)
        for _ in 0..<300 {
            let pieces = pieces(using: &random)
            var refs: [Int64: [Int64]] = [:]
            var coords: [Int64: (lat: Int32, lon: Int32)] = [:]
            for (index, piece) in pieces.enumerated() {
                refs[Int64(index + 1)] = piece
                for id in piece { coords[id] = (Int32(id % 1000), Int32(id / 1000)) }
            }
            let built = TileSplitter.RingBuilder.rings(
                of: (1...pieces.count).map(Int64.init),
                refs: refs,
                coords: TileSplitter.RingCoords(coords)
            )
            let plain = Self.plainRings(pieces: pieces)
            let expected = plain.closed.map { ring in ring.map { coords[$0]! } }
            XCTAssertEqual(built.closed.count, expected.count)
            for (a, b) in zip(built.closed, expected) {
                XCTAssertTrue(a.elementsEqual(b, by: { $0.lat == $1.lat && $0.lon == $1.lon }), "a ring differs")
            }
            let looseIDs = Set(plain.open.flatMap { $0 })
            if looseIDs.isEmpty {
                XCTAssertNil(built.openBBox)
            } else {
                XCTAssertEqual(built.openBBox?.minLat, looseIDs.map { coords[$0]!.lat }.min())
                XCTAssertEqual(built.openBBox?.maxLon, looseIDs.map { coords[$0]!.lon }.max())
            }
        }
    }

    func testAThousandPiecesJoinInReasonableTime() {
        // O(pieces^2) with a prepend that moved the whole chain took seconds here.
        let count = 4000
        var refs: [Int64: [Int64]] = [:]
        var coords: [Int64: (lat: Int32, lon: Int32)] = [:]
        for i in 0..<count {
            let a = Int64(i), b = Int64((i + 1) % count)
            refs[Int64(i + 1)] = [a, b]
            coords[a] = (Int32(i), Int32(i))
        }
        let started = Date()
        let built = TileSplitter.RingBuilder.rings(
            of: (1...count).map(Int64.init),
            refs: refs,
            coords: TileSplitter.RingCoords(coords)
        )
        XCTAssertEqual(built.closed.count, 1)
        XCTAssertEqual(built.closed.first?.count, count + 1)
        XCTAssertLessThan(Date().timeIntervalSince(started), 2)
    }

    // MARK: The table of ring nodes

    func testTheTableAnswersForEveryNodePutAndForNoOther() {
        // Sparse ids over many fences and a short last window.
        var ids: [Int64] = []
        var id: Int64 = 100
        for step in 0..<10_007 {
            id += Int64(1 + (step * 7) % 13)
            ids.append(id)
        }
        let table = TileSplitter.RingCoords(ids: ids)
        // Every third node is in no file.
        for (rank, id) in ids.enumerated() where rank % 3 != 0 {
            table.put(Int32(truncatingIfNeeded: id), Int32(rank), at: rank)
        }
        for (rank, id) in ids.enumerated() {
            if rank % 3 == 0 {
                XCTAssertNil(table[id], "node \(id) was never put")
            } else {
                XCTAssertEqual(table[id]?.lat, Int32(truncatingIfNeeded: id))
                XCTAssertEqual(table[id]?.lon, Int32(rank))
            }
            XCTAssertNil(table[id + 1].flatMap { _ in ids.contains(id + 1) ? nil : 1 }, "an id between 2 held")
        }
        XCTAssertNil(table[0])
        XCTAssertNil(table[ids[0] - 1])
        XCTAssertNil(table[id + 1])
        XCTAssertNil(table[Int64.max])
        XCTAssertNil(table[Int64.min])
    }

    func testTheFirstPlaceOfANodeStands() {
        let table = TileSplitter.RingCoords(ids: [5, 9])
        table.put(1, 2, at: 1)
        table.put(7, 8, at: 1)
        XCTAssertEqual(table[9]?.lat, 1)
        XCTAssertEqual(table[9]?.lon, 2)
        XCTAssertNil(table[5])
        XCTAssertNil(TileSplitter.RingCoords(ids: [])[5])
    }

    func testAPlaceAndItsFileFitOneWordAtTheEdgesOfTheMap() {
        let edge: Int32 = 1 << 23
        for (lat, lon, file) in [(edge, -edge, 0), (-edge, edge, TileSplitter.RingCoords.fileLimit), (0, 0, 3)] {
            let word = TileSplitter.RingCoords.pack(lat, lon, file: file)
            XCTAssertNotEqual(word, 0, "0 is a free slot")
            let back = TileSplitter.RingCoords.unpack(word)
            XCTAssertEqual(back.lat, lat)
            XCTAssertEqual(back.lon, lon)
            XCTAssertEqual(back.file, file)
        }
    }

    func testAnEarlierFileStandsAndOnlyTheSameFileConflicts() {
        let table = TileSplitter.RingCoords(ids: [5, 9])
        table.put(1, 2, at: 1, file: 0)
        // Another file at another place: overlapping extracts, the earlier one stands.
        table.put(7, 8, at: 1, file: 1)
        XCTAssertFalse(table.takeConflict())
        // The same file at the same place: nothing to decide.
        table.put(1, 2, at: 1, file: 0)
        XCTAssertFalse(table.takeConflict())
        XCTAssertEqual(table[9]?.lat, 1)
        // The same file at another place: which copy stands would depend on the readers.
        table.put(3, 4, at: 1, file: 0)
        XCTAssertTrue(table.takeConflict())
        XCTAssertFalse(table.takeConflict(), "asked once")
    }

    func testAFileReadAgainSettlesAsOneReaderInOrderDid() {
        let table = TileSplitter.RingCoords(ids: [5, 9])
        table.put(1, 1, at: 0, file: 0)
        table.put(2, 2, at: 1, file: 1)
        table.forget(file: 1)
        XCTAssertNil(table[9], "the file's own places are gone")
        XCTAssertEqual(table[5]?.lat, 1, "another file's stay")
        // 1 input: the last copy in the file stands.
        table.settle(3, 3, at: 1, file: 1, lastStands: true)
        table.settle(4, 4, at: 1, file: 1, lastStands: true)
        XCTAssertEqual(table[9]?.lat, 4)
        // Several: the first stands, and an earlier file's place is never replaced.
        table.forget(file: 1)
        table.settle(3, 3, at: 1, file: 1, lastStands: false)
        table.settle(4, 4, at: 1, file: 1, lastStands: false)
        table.settle(6, 6, at: 0, file: 1, lastStands: false)
        XCTAssertEqual(table[9]?.lat, 3)
        XCTAssertEqual(table[5]?.lat, 1)
    }

    func testTheWantedIDsSayWhereAnIDStands() {
        var wanted = TileSplitter.WantedIDs(sorted: [3, 8, 20, 21])
        XCTAssertNil(wanted.rank(of: 1))
        XCTAssertEqual(wanted.rank(of: 3), 0)
        XCTAssertNil(wanted.rank(of: 4))
        XCTAssertEqual(wanted.rank(of: 20), 2)
        XCTAssertEqual(wanted.rank(of: 21), 3)
        XCTAssertNil(wanted.rank(of: 99))
        // A worker starting its own run of blocks begins below where the last one stopped.
        XCTAssertEqual(wanted.rank(of: 8), 1)
        XCTAssertTrue(wanted.wants(21))
    }
}
