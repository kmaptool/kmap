import XCTest
@testable import kmap
#if canImport(CryptoKit)
import CryptoKit
#endif

/// MD5, which decides whether a large download is kept or fetched again.
///
/// Checked against RFC 1321, against the same bytes fed in arbitrary pieces, and where
/// CryptoKit is available against CryptoKit itself.
final class MD5Tests: XCTestCase {

    // MARK: RFC 1321

    /// The suite printed in the appendix of the RFC itself.
    func testTheVectorsInTheSpecification() {
        let cases: [(String, String)] = [
            ("", "d41d8cd98f00b204e9800998ecf8427e"),
            ("a", "0cc175b9c0f1b6a831c399e269772661"),
            ("abc", "900150983cd24fb0d6963f7d28e17f72"),
            ("message digest", "f96b697d7cb7938d525a2f31aaf161d0"),
            ("abcdefghijklmnopqrstuvwxyz", "c3fcd3d76192e4007dfb496cca67e13b"),
            ("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789",
             "d174ab98d277d9f5a5611c2c9f419d9f"),
            ("12345678901234567890123456789012345678901234567890"
             + "123456789012345678901234567890",
             "57edf4a22be3c955ac49da2e2107b67a")
        ]
        for (input, expected) in cases {
            XCTAssertEqual(MD5.hex(of: Array(input.utf8)), expected, "for \"\(input)\"")
        }
    }

    /// A digest is 32 lowercase hex characters, with leading zeros kept.
    func testTheDigestIsThirtyTwoLowercaseHexCharacters() {
        // A digest byte below 0x10 is where an unpadded formatter drops a character.
        let digest = MD5.hex(of: Array("\u{1}".utf8))
        XCTAssertEqual(digest.count, 32)
        XCTAssertEqual(digest, "55a54008ad1ba589aa210d2629c1df41")
        XCTAssertTrue(digest.allSatisfy { $0.isHexDigit && !$0.isUppercase })
    }

    // MARK: Block boundaries

    func testTheLengthsAroundEveryBoundaryThePaddingCaresAbout() {
        // At 55/56 the length no longer fits the final block and a second is appended;
        // 63/64/65 is the block itself.
        for count in [0, 1, 54, 55, 56, 57, 63, 64, 65, 119, 120, 127, 128, 129] {
            let payload = (0..<count).map { UInt8($0 % 251) }
            XCTAssertEqual(MD5.hex(of: payload), reference(payload),
                           "for \(count) bytes")
        }
    }

    func testFeedingItInPiecesGivesTheSameAnswerAsFeedingItWhole() {
        let payload = (0..<5000).map { UInt8($0 % 251) }
        let whole = MD5.hex(of: payload)

        // Chunk sizes below, at and straddling a block boundary.
        for chunk in [1, 3, 17, 63, 64, 65, 127, 128, 1000, 4096, 5000, 9999] {
            var hasher = MD5()
            var offset = 0
            while offset < payload.count {
                let end = min(offset + chunk, payload.count)
                hasher.update(Array(payload[offset..<end]))
                offset = end
            }
            XCTAssertEqual(hasher.finalizeHex(), whole, "in \(chunk)-byte pieces")
        }
    }

    func testAnEmptyUpdateChangesNothing() {
        var hasher = MD5()
        hasher.update([UInt8]())
        hasher.update(Array("abc".utf8))
        hasher.update([UInt8]())
        hasher.update(Data())
        XCTAssertEqual(hasher.finalizeHex(), "900150983cd24fb0d6963f7d28e17f72")
    }

    func testDataAndBytesAreHashedAlike() {
        let payload = (0..<300).map { UInt8($0 % 251) }
        XCTAssertEqual(MD5.hex(of: payload), MD5.hex(of: Data(payload)))
    }

    // MARK: Sizes past a single block count

    func testSomethingLargerThanTheLengthFieldWouldNoticeIfItWereWrong() {
        // A megabyte makes the bit count exceed what a byte count would hold.
        let payload = [UInt8](repeating: 0x61, count: 1 << 20)
        XCTAssertEqual(MD5.hex(of: payload), reference(payload))
    }

    // MARK: Against the implementation kmap used to use

    #if canImport(CryptoKit)
    func testItAgreesWithCryptoKitOnEveryLengthThroughTwoBlocks() {
        // Checksums recorded by earlier builds came from CryptoKit, so the two must agree.
        for count in 0...200 {
            let payload = (0..<count).map { UInt8(($0 &* 31 &+ 7) % 256) }
            let theirs = Insecure.MD5.hash(data: Data(payload))
                .map { String(format: "%02x", $0) }.joined()
            XCTAssertEqual(MD5.hex(of: payload), theirs, "for \(count) bytes")
        }
    }

    func testItAgreesWithCryptoKitOnSomethingTheSizeOfARealChunk() {
        let payload = (0..<(3 * 1024 * 1024 + 517)).map { UInt8($0 % 256) }
        let theirs = Insecure.MD5.hash(data: Data(payload))
            .map { String(format: "%02x", $0) }.joined()
        XCTAssertEqual(MD5.hex(of: payload), theirs)
    }
    #endif

    // MARK: Keeping up with the disk

    func testItHashesFastEnoughToNotBeWhatAVerifyIsWaitingFor() throws {
        // A guard against losing the unrolling rather than a benchmark: a debug build is
        // dominated by bounds checks and says nothing about a release binary.
        #if DEBUG
        throw XCTSkip("timing means nothing without optimisation")
        #else
        let payload = [UInt8](repeating: 0x37, count: 64 << 20)
        let started = Date()
        _ = MD5.hex(of: payload)
        let rate = Double(payload.count) / Date().timeIntervalSince(started) / 1_048_576
        XCTAssertGreaterThan(rate, 300, "MD5 ran at \(Int(rate)) MB/s")
        #endif
    }

    // MARK: A second implementation to check the first against

    /// MD5 written the plain way: a whole message buffer, no streaming, no partial
    /// blocks. Shares no code with the implementation under test.
    private func reference(_ message: [UInt8]) -> String {
        var padded = message
        padded.append(0x80)
        while padded.count % 64 != 56 { padded.append(0) }
        let bits = UInt64(message.count) * 8
        for i in 0..<8 { padded.append(UInt8((bits >> (8 * UInt64(i))) & 0xFF)) }

        let s: [UInt32] = [
            7, 12, 17, 22, 7, 12, 17, 22, 7, 12, 17, 22, 7, 12, 17, 22,
            5, 9, 14, 20, 5, 9, 14, 20, 5, 9, 14, 20, 5, 9, 14, 20,
            4, 11, 16, 23, 4, 11, 16, 23, 4, 11, 16, 23, 4, 11, 16, 23,
            6, 10, 15, 21, 6, 10, 15, 21, 6, 10, 15, 21, 6, 10, 15, 21
        ]
        // Computed rather than copied, so a typo in the table under test is not repeated.
        let k = (0..<64).map { UInt32(UInt64(abs(sin(Double($0 + 1))) * 4_294_967_296.0)) }

        var a0: UInt32 = 0x6745_2301, b0: UInt32 = 0xefcd_ab89
        var c0: UInt32 = 0x98ba_dcfe, d0: UInt32 = 0x1032_5476

        for block in stride(from: 0, to: padded.count, by: 64) {
            var m = [UInt32](repeating: 0, count: 16)
            for j in 0..<16 {
                var value: UInt32 = 0
                for byte in 0..<4 {
                    value |= UInt32(padded[block + j * 4 + byte]) << (8 * UInt32(byte))
                }
                m[j] = value
            }
            var (a, b, c, d) = (a0, b0, c0, d0)
            for i in 0..<64 {
                var f: UInt32
                var g: Int
                switch i {
                case 0..<16:  f = (b & c) | (~b & d); g = i
                case 16..<32: f = (d & b) | (~d & c); g = (5 * i + 1) % 16
                case 32..<48: f = b ^ c ^ d;          g = (3 * i + 5) % 16
                default:      f = c ^ (b | ~d);       g = (7 * i) % 16
                }
                f = f &+ a &+ k[i] &+ m[g]
                a = d; d = c; c = b
                b = b &+ ((f << s[i]) | (f >> (32 - s[i])))
            }
            a0 = a0 &+ a; b0 = b0 &+ b; c0 = c0 &+ c; d0 = d0 &+ d
        }

        var digest = [UInt8]()
        for word in [a0, b0, c0, d0] {
            for byte in 0..<4 { digest.append(UInt8((word >> (8 * UInt32(byte))) & 0xFF)) }
        }
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
