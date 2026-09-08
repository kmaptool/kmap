import XCTest
@testable import kmap

/// SHA-256 against the vectors FIPS 180-4 and RFC 6234 publish, since a digest that is
/// wrong in a way nothing notices would let a corrupt download through.
final class SHA256Tests: XCTestCase {

    private func hex(_ text: String) -> String {
        SHA256.hex(of: Array(text.utf8))
    }

    func testThePublishedVectors() {
        XCTAssertEqual(hex(""),
            "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
        XCTAssertEqual(hex("abc"),
            "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        XCTAssertEqual(hex("abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq"),
            "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1")
        XCTAssertEqual(hex(String(repeating: "a", count: 1_000_000)),
            "cdc76e5c9914fb9281a1c7e284d73e67f1809a48a497200e046d39ccc7112cd0")
    }

    func testABlockBoundaryIsWhereALengthBugWouldShow() {
        // 55, 56 and 64 bytes: the last message that fits its padding, the first that
        // needs a second block, and an exact block.
        for count in [55, 56, 63, 64, 65, 119, 120] {
            let text = String(repeating: "x", count: count)
            var streamed = SHA256()
            for byte in Array(text.utf8) { streamed.update([byte]) }
            XCTAssertEqual(streamed.finalizeHex(), hex(text), "\(count) bytes")
        }
    }

    func testFeedingItInPiecesGivesTheSameDigestAsFeedingItAtOnce() {
        let bytes = (0..<10_000).map { UInt8($0 % 251) }
        var piecemeal = SHA256()
        var offset = 0
        for size in [1, 7, 64, 100, 1000, 4096] where offset < bytes.count {
            let end = min(offset + size, bytes.count)
            piecemeal.update(Array(bytes[offset..<end]))
            offset = end
        }
        piecemeal.update(Array(bytes[offset...]))
        XCTAssertEqual(piecemeal.finalizeHex(), SHA256.hex(of: bytes))
    }

    func testTheRoundConstantsAreTheCubeRootsTheyClaimToBe() {
        // The first thirty-two bits of the fractional part of the cube root of each of the
        // first sixty-four primes.
        var primes: [Int] = []
        var candidate = 2
        while primes.count < 64 {
            if (2..<candidate).allSatisfy({ candidate % $0 != 0 }) { primes.append(candidate) }
            candidate += 1
        }
        let derived = primes.map { prime -> UInt32 in
            let fraction = cbrt(Double(prime)).truncatingRemainder(dividingBy: 1)
            return UInt32(fraction * 4_294_967_296)
        }
        var hasher = SHA256()
        hasher.update([])
        XCTAssertEqual(derived.count, 64)
        for (i, value) in derived.enumerated() {
            XCTAssertEqual(SHA256.constant(i), value, "constant \(i)")
        }
    }

    func testAFileIsHashedTheSameAsItsBytes() throws {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("kmap-sha-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: url) }
        let bytes = Data((0..<300_000).map { UInt8($0 % 253) })
        try bytes.write(to: url)
        XCTAssertEqual(SHA256.hex(ofFileAt: url, chunk: 4096), SHA256.hex(of: bytes))
    }

    func testAFileThatIsNotThereHasNoDigestRatherThanAnEmptyOne() {
        XCTAssertNil(SHA256.hex(ofFileAt: URL(fileURLWithPath: "/no/such/file")))
    }
}
