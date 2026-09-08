import XCTest
@testable import kmap

/// Deflate and inflate, from the system's zlib.
///
/// The boundary is what is checked: a complete zlib stream rather than a bare deflate
/// body, a damaged stream refused rather than half-inflated, and a declared size
/// checked against what came out.
final class ZlibTests: XCTestCase {

    private func roundTrip(_ payload: [UInt8], file: StaticString = #filePath,
                           line: UInt = #line) throws -> [UInt8] {
        let packed = try XCTUnwrap(Zlib.deflate(payload), "zlib declined to compress",
                                   file: file, line: line)
        var out = [UInt8](repeating: 0, count: payload.count)
        let written = try out.withUnsafeMutableBufferPointer { buffer in
            try packed.withUnsafeBytes { try Zlib.inflate($0, into: buffer) }
        }
        XCTAssertEqual(written, payload.count, file: file, line: line)
        return out
    }

    // MARK: A complete stream, not a bare body

    func testWhatComesOutIsAWholeZlibStreamAndNotJustTheDeflateBody() throws {
        let packed = try XCTUnwrap(Zlib.deflate(Array("the quick brown fox".utf8)))
        // 0x78 is deflate with a 32 KB window; the two header bytes read as a big-endian
        // value that is a multiple of 31.
        XCTAssertEqual(packed[0], 0x78)
        XCTAssertEqual((Int(packed[0]) << 8 | Int(packed[1])) % 31, 0)
        // A four-byte adler32 tail follows; without it nothing checks the inflated bytes.
        XCTAssertGreaterThan(packed.count, 2 + 4)
    }

    // MARK: Round trips

    func testTextComesBackTheSame() throws {
        let payload = Array(String(repeating: "kmap builds Garmin maps. ", count: 400).utf8)
        XCTAssertEqual(try roundTrip(payload), payload)
    }

    func testBytesThatDoNotCompressComeBackTheSame() throws {
        // Input that zlib gains nothing on still has to survive the round trip.
        var generator = SystemRandomNumberGenerator()
        let payload = (0..<50_000).map { _ in UInt8.random(in: 0...255, using: &generator) }
        XCTAssertEqual(try roundTrip(payload), payload)
    }

    func testASingleByteSurvives() throws {
        XCTAssertEqual(try roundTrip([0x2A]), [0x2A])
    }

    func testAPayloadTheSizeOfTheFormatsLargestBlobSurvives() throws {
        // 32 MB is the PBF ceiling, and the one size at which a wrong buffer bound shows.
        let payload = [UInt8](repeating: 0x5A, count: 32 << 20)
        XCTAssertEqual(try roundTrip(payload), payload)
    }

    // MARK: Refusing what it should refuse

    func testNothingIsCompressedFromAnEmptyBuffer() {
        XCTAssertNil(Zlib.deflate([]))
    }

    func testAStreamWithAFlippedByteIsRefusedRatherThanHalfInflated() throws {
        let payload = Array(String(repeating: "contour lines in metres. ", count: 200).utf8)
        var packed = try XCTUnwrap(Zlib.deflate(payload))
        packed[packed.count / 2] ^= 0xFF
        var out = [UInt8](repeating: 0, count: payload.count)
        XCTAssertThrowsError(try out.withUnsafeMutableBufferPointer { buffer in
            try packed.withUnsafeBytes { try Zlib.inflate($0, into: buffer) }
        })
    }

    func testADamagedChecksumIsRefusedEvenThoughTheBodyInflated() throws {
        // The adler32 tail is verified, so damage in the last four bytes is not read as
        // good data.
        let payload = Array(String(repeating: "elevation. ", count: 300).utf8)
        var packed = try XCTUnwrap(Zlib.deflate(payload))
        packed[packed.count - 1] ^= 0x01
        var out = [UInt8](repeating: 0, count: payload.count)
        XCTAssertThrowsError(try out.withUnsafeMutableBufferPointer { buffer in
            try packed.withUnsafeBytes { try Zlib.inflate($0, into: buffer) }
        })
    }

    func testAnEmptyStreamIsRefused() {
        var out = [UInt8](repeating: 0, count: 16)
        XCTAssertThrowsError(try out.withUnsafeMutableBufferPointer { buffer in
            try [UInt8]().withUnsafeBytes { try Zlib.inflate($0, into: buffer) }
        })
    }

    func testABufferTooSmallForTheStreamIsAFailureRatherThanATruncation() throws {
        let payload = Array(String(repeating: "sea and shorelines. ", count: 200).utf8)
        let packed = try XCTUnwrap(Zlib.deflate(payload))
        var out = [UInt8](repeating: 0, count: payload.count / 2)
        XCTAssertThrowsError(try out.withUnsafeMutableBufferPointer { buffer in
            try packed.withUnsafeBytes { try Zlib.inflate($0, into: buffer) }
        })
    }

    // MARK: The declared size

    func testAStreamThatInflatesToADifferentSizeThanClaimedIsRefused() throws {
        // A PBF blob carries its own uncompressed size; a GeoTIFF tile's is implied by
        // its dimensions.
        let payload = Array("thirty-two bytes of nothing much".utf8)
        let packed = try XCTUnwrap(Zlib.deflate(payload))
        var out = [UInt8](repeating: 0, count: payload.count)
        XCTAssertThrowsError(try out.withUnsafeMutableBufferPointer { buffer in
            try packed.withUnsafeBytes {
                try Zlib.inflate($0, into: buffer, expecting: payload.count - 1)
            }
        }) { error in
            XCTAssertEqual(error as? Zlib.Failure,
                           .unexpectedSize(expected: payload.count - 1, got: payload.count))
        }
    }

    func testAStreamThatInflatesToExactlyItsClaimedSizeIsAccepted() throws {
        let payload = Array("thirty-two bytes of nothing much".utf8)
        let packed = try XCTUnwrap(Zlib.deflate(payload))
        var out = [UInt8](repeating: 0, count: payload.count)
        XCTAssertNoThrow(try out.withUnsafeMutableBufferPointer { buffer in
            try packed.withUnsafeBytes {
                try Zlib.inflate($0, into: buffer, expecting: payload.count)
            }
        })
        XCTAssertEqual(out, payload)
    }

    // MARK: Several at once

    func testManyStreamsInflateAtOnceWithoutTreadingOnEachOther() {
        // The one-shot calls hold no state between them, so blobs inflate on every core
        // at once, each into a buffer of its own.
        let payloads = (0..<64).map { i in
            Array(String(repeating: "block \(i) ", count: 500 + i).utf8)
        }
        let packed = payloads.map { Zlib.deflate($0) }
        var results = [[UInt8]](repeating: [], count: payloads.count)
        results.withUnsafeMutableBufferPointer { slots in
            DispatchQueue.concurrentPerform(iterations: payloads.count) { i in
                guard let stream = packed[i] else { return }
                var out = [UInt8](repeating: 0, count: payloads[i].count)
                _ = try? out.withUnsafeMutableBufferPointer { buffer in
                    try stream.withUnsafeBytes { try Zlib.inflate($0, into: buffer) }
                }
                slots[i] = out
            }
        }
        XCTAssertEqual(results, payloads)
    }
}
