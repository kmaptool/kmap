import XCTest

@testable import kmap

/// Deflate and inflate, through libdeflate.
///
/// The boundary is what is checked: a complete wrapped stream rather than a bare deflate
/// body, a damaged stream refused rather than half-inflated, and a declared size
/// checked against what came out.
final class DeflateTests: XCTestCase {
    private func roundTrip(
        _ payload: [UInt8],
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> [UInt8] {
        let packed = try XCTUnwrap(
            Deflate.deflate(payload),
            "libdeflate declined to compress",
            file: file,
            line: line
        )
        var out = [UInt8](repeating: 0, count: payload.count)
        let written = try out.withUnsafeMutableBufferPointer { buffer in
            try packed.withUnsafeBytes { try Deflate.inflate($0, into: buffer) }
        }
        XCTAssertEqual(written, payload.count, file: file, line: line)
        return out
    }

    // MARK: A complete stream, not a bare body

    func testWhatComesOutIsAWholeWrappedStreamAndNotJustTheDeflateBody() throws {
        let packed = try XCTUnwrap(Deflate.deflate(Array("the quick brown fox".utf8)))
        // 0x78 is deflate with a 32 KB window; the 2 header bytes read as a big-endian
        // value that is a multiple of 31.
        XCTAssertEqual(packed[0], 0x78)
        XCTAssertEqual((Int(packed[0]) << 8 | Int(packed[1])) % 31, 0)
        // A 4-byte adler32 tail follows; without it nothing checks the inflated bytes.
        XCTAssertGreaterThan(packed.count, 2 + 4)
    }

    func testAStreamIsTheSameBytesOnEveryMachine() throws {
        // The library comes with kmap, so a tile does not depend on where it was packed.
        // A new version of it may pack differently, and this is where that shows.
        // Text with noise in it, from arithmetic that is the same everywhere.
        let word = Array("node way relation highway name ".utf8)
        var state: UInt32 = 20_261_008
        var payload: [UInt8] = []
        for _ in 0..<4000 {
            state = state &* 1_664_525 &+ 1_013_904_223
            payload += word[0..<(1 + Int(state >> 16) % (word.count - 1))]
            payload.append(UInt8(truncatingIfNeeded: state >> 8))
        }
        let packed = try XCTUnwrap(Deflate.deflate(payload))
        XCTAssertEqual(MD5.hex(of: packed), "bb4085a85965c3051bee4748cecd1524")
    }

    func testBytesAfterTheEndOfAStreamAreLeftAlone() throws {
        // A GeoTIFF may count padding into a tile's length.
        let payload = Array(String(repeating: "padded. ", count: 100).utf8)
        let packed = try XCTUnwrap(Deflate.deflate(payload)) + [0x00, 0xFF, 0x00]
        var out = [UInt8](repeating: 0, count: payload.count)
        let written = try out.withUnsafeMutableBufferPointer { buffer in
            try packed.withUnsafeBytes { try Deflate.inflate($0, into: buffer) }
        }
        XCTAssertEqual(written, payload.count)
        XCTAssertEqual(out, payload)
    }

    // MARK: Round trips

    func testTextComesBackTheSame() throws {
        let payload = Array(String(repeating: "kmap builds Garmin maps. ", count: 400).utf8)
        XCTAssertEqual(try roundTrip(payload), payload)
    }

    func testBytesThatDoNotCompressComeBackTheSame() throws {
        // Input that deflate gains nothing on still has to survive the round trip.
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
        XCTAssertNil(Deflate.deflate([]))
    }

    func testAStreamWithAFlippedByteIsRefusedRatherThanHalfInflated() throws {
        let payload = Array(String(repeating: "contour lines in metres. ", count: 200).utf8)
        var packed = try XCTUnwrap(Deflate.deflate(payload))
        packed[packed.count / 2] ^= 0xFF
        var out = [UInt8](repeating: 0, count: payload.count)
        XCTAssertThrowsError(
            try out.withUnsafeMutableBufferPointer { buffer in
                try packed.withUnsafeBytes { try Deflate.inflate($0, into: buffer) }
            }
        )
    }

    func testADamagedChecksumIsRefusedEvenThoughTheBodyInflated() throws {
        // The adler32 tail is verified, so damage in the last 4 bytes is not read as
        // good data.
        let payload = Array(String(repeating: "elevation. ", count: 300).utf8)
        var packed = try XCTUnwrap(Deflate.deflate(payload))
        packed[packed.count - 1] ^= 0x01
        var out = [UInt8](repeating: 0, count: payload.count)
        XCTAssertThrowsError(
            try out.withUnsafeMutableBufferPointer { buffer in
                try packed.withUnsafeBytes { try Deflate.inflate($0, into: buffer) }
            }
        )
    }

    func testAnEmptyStreamIsRefused() {
        var out = [UInt8](repeating: 0, count: 16)
        XCTAssertThrowsError(
            try out.withUnsafeMutableBufferPointer { buffer in
                try [UInt8]().withUnsafeBytes { try Deflate.inflate($0, into: buffer) }
            }
        )
    }

    func testABufferTooSmallForTheStreamIsAFailureRatherThanATruncation() throws {
        let payload = Array(String(repeating: "sea and shorelines. ", count: 200).utf8)
        let packed = try XCTUnwrap(Deflate.deflate(payload))
        var out = [UInt8](repeating: 0, count: payload.count / 2)
        XCTAssertThrowsError(
            try out.withUnsafeMutableBufferPointer { buffer in
                try packed.withUnsafeBytes { try Deflate.inflate($0, into: buffer) }
            }
        )
    }

    // MARK: The declared size

    func testAStreamThatInflatesToADifferentSizeThanClaimedIsRefused() throws {
        // A PBF blob carries its own uncompressed size; a GeoTIFF tile's is implied by
        // its dimensions.
        let payload = Array("thirty-two bytes of nothing much".utf8)
        let packed = try XCTUnwrap(Deflate.deflate(payload))
        var out = [UInt8](repeating: 0, count: payload.count)
        XCTAssertThrowsError(
            try out.withUnsafeMutableBufferPointer { buffer in
                try packed.withUnsafeBytes {
                    try Deflate.inflate($0, into: buffer, expecting: payload.count - 1)
                }
            }
        ) { error in
            XCTAssertEqual(
                error as? Deflate.Failure,
                .unexpectedSize(expected: payload.count - 1, got: payload.count)
            )
        }
    }

    func testAStreamThatInflatesToExactlyItsClaimedSizeIsAccepted() throws {
        let payload = Array("thirty-two bytes of nothing much".utf8)
        let packed = try XCTUnwrap(Deflate.deflate(payload))
        var out = [UInt8](repeating: 0, count: payload.count)
        XCTAssertNoThrow(
            try out.withUnsafeMutableBufferPointer { buffer in
                try packed.withUnsafeBytes {
                    try Deflate.inflate($0, into: buffer, expecting: payload.count)
                }
            }
        )
        XCTAssertEqual(out, payload)
    }

    // MARK: Several at once

    func testManyStreamsInflateAtOnceWithoutTreadingOnEachOther() {
        // Each call takes working memory of its own, so blobs inflate on every core at
        // once, each into a buffer of its own.
        let payloads = (0..<64).map { i in
            Array(String(repeating: "block \(i) ", count: 500 + i).utf8)
        }
        let packed = payloads.map { Deflate.deflate($0) }
        var results = [[UInt8]](repeating: [], count: payloads.count)
        results.withUnsafeMutableBufferPointer { slots in
            DispatchQueue.concurrentPerform(iterations: payloads.count) { i in
                guard let stream = packed[i] else { return }
                var out = [UInt8](repeating: 0, count: payloads[i].count)
                _ = try? out.withUnsafeMutableBufferPointer { buffer in
                    try stream.withUnsafeBytes { try Deflate.inflate($0, into: buffer) }
                }
                slots[i] = out
            }
        }
        XCTAssertEqual(results, payloads)
    }
}
