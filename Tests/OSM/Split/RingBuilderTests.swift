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
                coords: coords
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
        let built = TileSplitter.RingBuilder.rings(of: (1...count).map(Int64.init), refs: refs, coords: coords)
        XCTAssertEqual(built.closed.count, 1)
        XCTAssertEqual(built.closed.first?.count, count + 1)
        XCTAssertLessThan(Date().timeIntervalSince(started), 2)
    }
}
