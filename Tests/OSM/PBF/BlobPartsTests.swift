import XCTest

@testable import kmap

/// What each blob of a file holds, learned by 1 pass and trusted by the next.
///
/// A blob skipped on a wrong answer is objects silently missing from the map, so the
/// answer is trusted only for the very file it was learned on.
final class BlobPartsTests: XCTestCase {
    private func file() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("blob-parts-\(UUID().uuidString).pbf")
        try FileTools.write(Data(repeating: 0, count: 100), to: url)
        return url
    }

    /// The blobs of a 100-byte buffer, cut at `cuts`.
    private func blobs(_ bytes: UnsafeRawBufferPointer, cutAt cuts: [Int]) -> [UnsafeRawBufferPointer] {
        zip([0] + cuts, cuts + [bytes.count]).map { UnsafeRawBufferPointer(rebasing: bytes[$0..<$1]) }
    }

    private func learn(_ url: URL, _ blobs: [UnsafeRawBufferPointer], _ parts: [OSMParts]) throws {
        let log = try XCTUnwrap(BlobParts.select(blobs, of: url, wanted: .nodes).log)
        for (blob, held) in parts.enumerated() { log.note(blob, holds: held) }
        log.keep()
    }

    func testALaterPassReadsOnlyTheBlobsHoldingWhatItWants() throws {
        let url = try file()
        defer { try? FileManager.default.removeItem(at: url) }
        try [UInt8](repeating: 0, count: 100).withUnsafeBytes { bytes in
            let layout = blobs(bytes, cutAt: [40, 70])
            try learn(url, layout, [.nodes, .ways, [.ways, .relations]])
            let ways = BlobParts.select(layout, of: url, wanted: .ways)
            XCTAssertNil(ways.log)
            XCTAssertEqual(ways.blobs.map(\.count), [30, 30])
            // A pass that wants everything always reads everything.
            XCTAssertEqual(BlobParts.select(layout, of: url, wanted: .all).blobs.count, 3)
        }
    }

    /// The same file name, size and time stamp, as a file system with a coarse clock
    /// shows a rewrite, but blobs laid out otherwise: nothing learned is trusted.
    func testBlobsLaidOutOtherwiseAreReadWhole() throws {
        let url = try file()
        defer { try? FileManager.default.removeItem(at: url) }
        try [UInt8](repeating: 0, count: 100).withUnsafeBytes { bytes in
            try learn(url, blobs(bytes, cutAt: [40, 70]), [.nodes, .ways, .ways])
            let moved = BlobParts.select(blobs(bytes, cutAt: [50, 70]), of: url, wanted: .nodes)
            XCTAssertNotNil(moved.log)
            XCTAssertEqual(moved.blobs.count, 3)
            let fewer = BlobParts.select(blobs(bytes, cutAt: [40]), of: url, wanted: .nodes)
            XCTAssertEqual(fewer.blobs.count, 2)
        }
    }
}
