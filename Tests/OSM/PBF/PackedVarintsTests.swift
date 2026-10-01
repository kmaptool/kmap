import XCTest

@testable import kmap

/// The packed decoders against `ProtoReader`: the same values out of every stream,
/// well formed or not.
final class PackedVarintsTests: XCTestCase {
    /// What `ProtoReader` gives, value by value, which is the definition.
    private func reference(_ bytes: [UInt8]) -> [UInt64] {
        bytes.withUnsafeBytes { raw in
            var out: [UInt64] = []
            var reader = ProtoReader(raw)
            while !reader.isAtEnd { out.append(reader.varint()) }
            return out
        }
    }

    private func zigzag(_ raw: UInt64) -> Int64 { Int64(bitPattern: raw >> 1) ^ -Int64(bitPattern: raw & 1) }

    private func check(_ bytes: [UInt8], _ note: String) {
        let expected = reference(bytes)
        bytes.withUnsafeBytes { raw in
            var plain = [Int64](repeating: 0, count: bytes.count + 1)
            let n = plain.withUnsafeMutableBufferPointer { PackedVarints.zigzag(raw, into: $0.baseAddress!) }
            XCTAssertEqual(Array(plain[0..<n]), expected.map(zigzag), note)

            var sums = [Int64](repeating: 0, count: bytes.count + 1)
            let m = sums.withUnsafeMutableBufferPointer { PackedVarints.zigzagSums(raw, into: $0.baseAddress!) }
            var running: Int64 = 0
            XCTAssertEqual(
                Array(sums[0..<m]),
                expected.map {
                    running &+= zigzag($0); return running
                },
                note
            )

            var narrow = [Int32](repeating: 0, count: bytes.count + 1)
            let k = narrow.withUnsafeMutableBufferPointer { PackedVarints.int32(raw, into: $0.baseAddress!) }
            XCTAssertEqual(Array(narrow[0..<k]), expected.map { Int32(truncatingIfNeeded: $0) }, note)
        }
    }

    private func encoded(_ value: UInt64) -> [UInt8] {
        var out: [UInt8] = []
        var v = value
        while v >= 0x80 {
            out.append(UInt8(v & 0x7F) | 0x80)
            v >>= 7
        }
        out.append(UInt8(v))
        return out
    }

    func testEveryLengthOfVarintComesOutAsTheReaderReadsIt() {
        var stream: [UInt8] = []
        for bits in 0..<64 {
            stream += encoded(1 << UInt64(bits))
            stream += encoded((1 << UInt64(bits)) - 1)
        }
        stream += encoded(UInt64.max)
        check(stream, "one of each length")
        check([], "nothing at all")
        check([0x00], "a single zero")
    }

    func testWellFormedStreamsOfEverySizeAgree() {
        var random = SplitMix64(state: 20_261_003)
        for size in [1, 2, 9, 10, 11, 19, 20, 21, 100, 5000] {
            var stream: [UInt8] = []
            for _ in 0..<size {
                // Mostly short, as node deltas are, with a long one now and then.
                let bits =
                    Int.random(in: 0..<20, using: &random) == 0
                    ? Int.random(in: 1...64, using: &random) : Int.random(in: 1...21, using: &random)
                stream += encoded(UInt64.random(in: 0...UInt64.max, using: &random) >> UInt64(64 - bits))
            }
            check(stream, "\(size) values")
        }
    }

    /// The vector decoder picks its way by the lengths ahead: 16 values of 1 byte, up
    /// to 4 of up to 4 bytes, up to 2 of up to 8, or 1 alone. Every mix of them here,
    /// at every offset into a 64-byte chunk.
    func testLongFieldsOfEveryMixOfLengthsAgree() {
        var random = SplitMix64(state: 20_261_005)
        func value(bytes: Int) -> [UInt8] {
            let bits = bytes * 7
            let top: UInt64 = bits >= 64 ? .max : (1 << UInt64(bits)) - 1
            let low: UInt64 = bytes == 1 ? 0 : 1 << UInt64(bits - 7)
            return encoded(UInt64.random(in: low...top, using: &random))
        }
        let mixes: [[Int]] = [
            [1], [2], [3], [4], [5], [8], [9], [10],
            [1, 2], [2, 3], [1, 4], [3, 4], [4, 5], [1, 5], [5, 8], [1, 8], [8, 9], [1, 10],
            [1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 2],
            [1, 2, 3, 4, 5, 6, 7, 8, 9, 10]
        ]
        for mix in mixes {
            for lead in 0..<17 {
                var stream = [UInt8](repeating: 0x01, count: lead)
                while stream.count < 400 { stream += value(bytes: mix.randomElement(using: &random) ?? 1) }
                check(stream, "lengths \(mix) after \(lead) single bytes")
            }
        }
        // The longest varints and the over-long, in the middle of a long field and at
        // each place in a chunk: 8 to 13 continuation bytes, then a byte that ends them.
        for lead in 0..<70 {
            for run in 8...13 {
                var stream: [UInt8] = []
                for _ in 0..<lead { stream += value(bytes: Int.random(in: 1...3, using: &random)) }
                stream += [UInt8](repeating: 0xFF, count: run) + [0x7F]
                for _ in 0..<100 { stream += value(bytes: Int.random(in: 1...3, using: &random)) }
                check(stream, "\(run) continuation bytes after \(lead) values")
            }
        }
    }

    func testMalformedStreamsAgreeWithTheReaderByteForByte() {
        // Truncated in the middle of a varint, over-long, all continuation bytes, noise:
        // the fast path hands these to the reader, so the answers are the reader's.
        check([0x80], "a continuation byte and no more")
        check([0x81, 0x82, 0x83], "truncated")
        check([UInt8](repeating: 0xFF, count: 9), "9 continuation bytes")
        check([UInt8](repeating: 0xFF, count: 10), "10 continuation bytes")
        check([UInt8](repeating: 0xFF, count: 11) + [0x01, 0x05], "over-long, then a value")
        check([UInt8](repeating: 0x80, count: 40) + [0x00, 0x07, 0x08], "40 continuation bytes, then values")
        check([0x05] + [UInt8](repeating: 0xFF, count: 30), "a value, then a run with no end")
        var random = SplitMix64(state: 20_261_004)
        for _ in 0..<4000 {
            // Past 64 bytes a field goes through the vector decoder first.
            let count = Int.random(in: 0...200, using: &random)
            // 1 byte in 2 continues, so runs of every length turn up, the over-long too.
            let noise = (0..<count).map { _ in UInt8.random(in: 0...255, using: &random) }
            check(noise, "noise \(noise)")
        }
    }
}
