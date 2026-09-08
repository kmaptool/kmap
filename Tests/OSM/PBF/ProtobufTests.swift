import XCTest
@testable import kmap

/// The protobuf wire format the rest of OSM/PBF rests on: a written value reads back the
/// same across each type's whole range, and a malformed message is refused.
final class ProtobufTests: XCTestCase {

    // MARK: Reading a buffer

    /// Runs `body` on a reader over `bytes`. The reader does not own its memory, so the
    /// buffer must outlive it.
    private func read<T>(_ bytes: [UInt8], _ body: (inout ProtoReader) -> T) -> T {
        var storage = bytes
        return storage.withUnsafeMutableBytes { raw in
            var reader = ProtoReader(UnsafeRawBufferPointer(raw))
            return body(&reader)
        }
    }

    private func written(_ body: (inout ProtoWriter) -> Void) -> [UInt8] {
        var writer = ProtoWriter()
        body(&writer)
        return writer.bytes
    }

    // MARK: Varints

    func testVarintEncodingIsTheCanonicalOne() {
        XCTAssertEqual(written { $0.varint(0) }, [0])
        XCTAssertEqual(written { $0.varint(1) }, [1])
        XCTAssertEqual(written { $0.varint(127) }, [0x7F])
        XCTAssertEqual(written { $0.varint(128) }, [0x80, 0x01])
        XCTAssertEqual(written { $0.varint(300) }, [0xAC, 0x02])
        XCTAssertEqual(written { $0.varint(16383) }, [0xFF, 0x7F])
        XCTAssertEqual(written { $0.varint(16384) }, [0x80, 0x80, 0x01])
        XCTAssertEqual(written { $0.varint(UInt64.max) },
                       [0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0x01])
    }

    func testVarintRoundTripsEveryBoundary() {
        var values: [UInt64] = [0, 1, 2, 127, 128, 129, 255, 256, 16383, 16384,
                                UInt64(UInt32.max), UInt64(UInt32.max) + 1, UInt64.max]
        // Varints change length at multiples of seven bits, so every bit position and its
        // neighbours are covered.
        for bit in 0..<64 {
            let value = UInt64(1) << bit
            values.append(value)
            values.append(value &- 1)
            values.append(value &+ 1)
        }
        for value in values {
            let bytes = written { $0.varint(value) }
            XCTAssertEqual(read(bytes) { $0.varint() }, value, "varint \(value)")
        }
    }

    func testVarintLengthGrowsEverySevenBits() {
        for length in 1...10 {
            let value = length == 10 ? UInt64.max : (UInt64(1) << (7 * length)) - 1
            XCTAssertEqual(written { $0.varint(value) }.count, length,
                           "\(value) should take \(length) byte(s)")
        }
    }

    func testZigzagRoundTripsAcrossTheWholeSignedRange() {
        var values: [Int64] = [0, -1, 1, -2, 2, 63, -64, Int64.max, Int64.min]
        for bit in 0..<63 {
            let value = Int64(1) << bit
            values.append(value)
            values.append(-value)
            values.append(value &- 1)
        }
        for value in values {
            let bytes = written { $0.zigzag(value) }
            XCTAssertEqual(read(bytes) { $0.zigzag() }, value, "zigzag \(value)")
        }
    }

    func testZigzagUsesTheEncodingProtobufSpecifies() {
        // The zigzag mapping is fixed by the format: small magnitudes of either sign stay
        // short.
        XCTAssertEqual(written { $0.zigzag(0) }, [0])
        XCTAssertEqual(written { $0.zigzag(-1) }, [1])
        XCTAssertEqual(written { $0.zigzag(1) }, [2])
        XCTAssertEqual(written { $0.zigzag(-2) }, [3])
        XCTAssertEqual(written { $0.zigzag(2147483647) }, [0xFE, 0xFF, 0xFF, 0xFF, 0x0F])
    }

    // MARK: Field keys

    func testFieldKeysCarryNumberAndWireType() {
        for number in [1, 2, 15, 16, 100, 1000, 536_870_911] {
            for wire in [0, 1, 2, 5] {
                let bytes = written { $0.key(number, wire) }
                let field = read(bytes) { $0.nextField() }
                XCTAssertEqual(field?.number, number)
                XCTAssertEqual(field?.wire, wire)
            }
        }
    }

    func testNextFieldReturnsNilAtTheEnd() {
        XCTAssertNil(read([]) { $0.nextField() })
        let one = written { $0.varintField(1, 42) }
        let count = read(one) { reader -> Int in
            var seen = 0
            while reader.nextField() != nil {
                _ = reader.varint()
                seen += 1
            }
            return seen
        }
        XCTAssertEqual(count, 1)
    }

    // MARK: Length-delimited fields

    func testLengthDelimitedIsAWindowOnTheSameMemory() {
        let payload: [UInt8] = [10, 20, 30, 40]
        let bytes = written { $0.bytesField(1, payload) }
        let copy = read(bytes) { reader -> [UInt8] in
            _ = reader.nextField()
            return Array(reader.lengthDelimited())
        }
        XCTAssertEqual(copy, payload)
    }

    func testEmptyLengthDelimitedIsEmptyAndNotNil() {
        let bytes = written { $0.bytesField(1, []) }
        let copy = read(bytes) { reader -> [UInt8] in
            _ = reader.nextField()
            return Array(reader.lengthDelimited())
        }
        XCTAssertEqual(copy, [])
    }

    func testStringFieldSurvivesTheAlphabetsAMapNeeds() {
        for text in ["", "Monaco", "Ливадия", "Großglockner", "北京", "🏔 Peak"] {
            let bytes = written { $0.stringField(1, text) }
            let decoded = read(bytes) { reader -> String in
                _ = reader.nextField()
                return String(decoding: reader.lengthDelimited(), as: UTF8.self)
            }
            XCTAssertEqual(decoded, text)
        }
    }

    // MARK: Skipping

    func testSkipStepsOverEachWireTypeExactly() {
        // Assembled by hand: the writer emits no fixed-width fields, since an OSM PBF has
        // none, but the reader must still step over them.
        var bytes: [UInt8] = []
        bytes += written { w in w.key(1, 0); w.varint(300) }       // varint
        bytes += written { $0.key(2, 1) } + [UInt8](repeating: 7, count: 8)   // fixed64
        bytes += written { $0.bytesField(3, [1, 2, 3]) }           // length-delimited
        bytes += written { $0.key(4, 5) } + [UInt8](repeating: 9, count: 4)   // fixed32
        bytes += written { $0.varintField(5, 99) }                 // the one to land on
        let value = read(bytes) { reader -> Int64? in
            while let field = reader.nextField() {
                if field.number == 5 { return Int64(bitPattern: reader.varint()) }
                reader.skip(wire: field.wire)
            }
            return nil
        }
        XCTAssertEqual(value, 99)
    }

    func testAnUnknownWireTypeAbandonsTheMessageRatherThanGuessing() {
        // Wire types 3 and 4 are protobuf's withdrawn groups, and have no length to skip by.
        let bytes = written { w in
            w.key(1, 3)
            w.varint(12345)
        }
        let finished = read(bytes) { reader -> Bool in
            guard let field = reader.nextField() else { return false }
            reader.skip(wire: field.wire)
            return reader.isAtEnd
        }
        XCTAssertTrue(finished)
    }

    // MARK: Malformed input

    func testATruncatedVarintStopsAtTheEndOfTheBuffer() {
        // Every byte says "more follows" and then the buffer ends.
        let bytes = [UInt8](repeating: 0x80, count: 5)
        let value = read(bytes) { $0.varint() }
        XCTAssertEqual(value, 0)
    }

    func testAVarintLongerThanSixtyFourBitsDoesNotRunAway() {
        // Eleven continuation bytes: beyond any value a UInt64 holds, and the read ends
        // inside the buffer.
        let bytes = [UInt8](repeating: 0xFF, count: 11) + [0x01]
        let stopped = read(bytes) { reader -> Bool in
            _ = reader.varint()
            return reader.index <= bytes.count
        }
        XCTAssertTrue(stopped)
    }

    func testALengthPastTheEndOfTheBufferIsClampedNotObeyed() {
        // A three-byte payload that declares a thousand.
        var bytes = written { $0.key(1, 2) }
        bytes.append(contentsOf: written { $0.varint(1000) })
        bytes.append(contentsOf: [1, 2, 3])
        let window = read(bytes) { reader -> Int in
            _ = reader.nextField()
            return reader.lengthDelimited().count
        }
        XCTAssertEqual(window, 3)
    }

    func testAnAbsurdLengthIsRefusedRatherThanCrashing() {
        // 2^63 bytes: a length that does not fit a signed Int.
        var bytes = written { $0.key(1, 2) }
        bytes.append(contentsOf: written { $0.varint(UInt64(1) << 63) })
        bytes.append(contentsOf: [1, 2, 3])
        let window = read(bytes) { reader -> Int in
            _ = reader.nextField()
            return reader.lengthDelimited().count
        }
        XCTAssertLessThanOrEqual(window, 3)
    }

    func testSkippingAnAbsurdLengthLeavesTheReaderAtTheEnd() {
        var bytes = written { $0.key(1, 2) }
        bytes.append(contentsOf: written { $0.varint(UInt64.max) })
        let atEnd = read(bytes) { reader -> Bool in
            guard let field = reader.nextField() else { return false }
            reader.skip(wire: field.wire)
            return reader.isAtEnd
        }
        XCTAssertTrue(atEnd)
    }

    func testSkippingFixedWidthFieldsPastTheEndDoesNotOverrun() {
        for wire in [1, 5] {
            let bytes = written { $0.key(1, wire) }      // key, then nothing
            let atEnd = read(bytes) { reader -> Bool in
                guard let field = reader.nextField() else { return false }
                reader.skip(wire: field.wire)
                return reader.isAtEnd
            }
            XCTAssertTrue(atEnd, "wire \(wire)")
        }
    }

    // MARK: Writing

    func testVarintFieldLeavesOutZeroTheWayProtobufDoes() {
        XCTAssertEqual(written { $0.varintField(1, 0) }, [])
        XCTAssertEqual(written { $0.varintField(1, 1) }.isEmpty, false)
    }

    func testNegativeVarintFieldsUseTheFullTenBytes() {
        // A plain int64 field is not zigzagged, so -1 is every bit set.
        let bytes = written { $0.varintField(1, -1) }
        XCTAssertEqual(bytes.count, 11)   // one key byte, ten of value
        let value = read(bytes) { reader -> Int64 in
            _ = reader.nextField()
            return Int64(bitPattern: reader.varint())
        }
        XCTAssertEqual(value, -1)
    }

    func testNestedMessagesCarryTheirOwnLength() {
        let bytes = written { w in
            w.message(1) { inner in
                inner.varintField(1, 7)
                inner.stringField(2, "gate")
            }
            w.varintField(2, 5)
        }
        var innerSeen: (id: Int64, name: String)?
        var outerSeen: Int64?
        _ = read(bytes) { reader -> Bool in
            while let field = reader.nextField() {
                switch (field.number, field.wire) {
                case (1, 2):
                    var inner = ProtoReader(reader.lengthDelimited())
                    var id: Int64 = 0
                    var name = ""
                    while let f = inner.nextField() {
                        switch f.number {
                        case 1: id = Int64(bitPattern: inner.varint())
                        case 2: name = String(decoding: inner.lengthDelimited(), as: UTF8.self)
                        default: inner.skip(wire: f.wire)
                        }
                    }
                    innerSeen = (id, name)
                case (2, 0): outerSeen = Int64(bitPattern: reader.varint())
                default: reader.skip(wire: field.wire)
                }
            }
            return true
        }
        XCTAssertEqual(innerSeen?.id, 7)
        XCTAssertEqual(innerSeen?.name, "gate")
        XCTAssertEqual(outerSeen, 5)
    }

    func testAnEmptyNestedMessageIsStillWritten() {
        let bytes = written { w in w.message(3) { _ in } }
        XCTAssertEqual(bytes, [3 << 3 | 2, 0])
    }

    func testMessagesNestToDepthWithoutLosingTheirLengths() {
        // Ten deep, each level carrying its own number, unpacked back out again.
        func build(_ depth: Int, into w: inout ProtoWriter) {
            guard depth > 0 else {
                w.varintField(15, 123)
                return
            }
            w.message(1) { inner in build(depth - 1, into: &inner) }
        }
        var writer = ProtoWriter()
        build(10, into: &writer)

        var bytes = writer.bytes
        let deepest = bytes.withUnsafeMutableBytes { raw -> Int64 in
            var window = UnsafeRawBufferPointer(raw)
            for _ in 0..<10 {
                var reader = ProtoReader(window)
                guard let field = reader.nextField(), field.number == 1 else { return -1 }
                window = reader.lengthDelimited()
            }
            var reader = ProtoReader(window)
            guard let field = reader.nextField(), field.number == 15 else { return -1 }
            return Int64(bitPattern: reader.varint())
        }
        XCTAssertEqual(deepest, 123)
    }

    // MARK: Packed repeats, the shape OSM leans on hardest

    func testAPackedRunOfZigzagsComesBackInOrder() {
        let deltas: [Int64] = [1, -1, 1_000_000, -1_000_000, 0, Int64.max, Int64.min]
        let payload = written { w in for d in deltas { w.zigzag(d) } }
        let bytes = written { $0.bytesField(2, payload) }
        let decoded = read(bytes) { reader -> [Int64] in
            _ = reader.nextField()
            var packed = ProtoReader(reader.lengthDelimited())
            var out: [Int64] = []
            while !packed.isAtEnd { out.append(packed.zigzag()) }
            return out
        }
        XCTAssertEqual(decoded, deltas)
    }
}
