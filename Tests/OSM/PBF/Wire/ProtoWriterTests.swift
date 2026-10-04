import XCTest

@testable import kmap

/// The writer: fields, nesting, and the zero that protobuf leaves out.
final class ProtoWriterTests: XCTestCase {
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

    func testVarintFieldLeavesOutZeroTheWayProtobufDoes() {
        XCTAssertEqual(written { $0.varintField(1, 0) }, [])
        XCTAssertEqual(written { $0.varintField(1, 1) }.isEmpty, false)
    }

    func testNegativeVarintFieldsUseTheFullTenBytes() {
        // A plain int64 field is not zigzagged, so -1 is every bit set.
        let bytes = written { $0.varintField(1, -1) }
        XCTAssertEqual(bytes.count, 11)  // one key byte, ten of value
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
}
