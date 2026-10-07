import XCTest

@testable import kmap

/// A damaged or hostile GeoTIFF is refused at the door: no huge allocation, no overflow
/// trap, no read of what the reader does not use.
final class GeoTIFFDamageTests: XCTestCase {
    private struct Tag {
        let tag: Int, type: Int, count: Int
        let bytes: [UInt8]
    }

    private static func le16(_ v: Int) -> [UInt8] { [UInt8(truncatingIfNeeded: v), UInt8(truncatingIfNeeded: v >> 8)] }
    private static func le32(_ v: Int) -> [UInt8] { (0..<4).map { UInt8(truncatingIfNeeded: v >> (8 * $0)) } }
    private static func le64(_ v: UInt64) -> [UInt8] {
        (0..<8).map { UInt8(truncatingIfNeeded: v >> (8 * UInt64($0))) }
    }
    private static func short(_ tag: Int, _ values: [Int]) -> Tag {
        Tag(tag: tag, type: 3, count: values.count, bytes: values.flatMap(le16))
    }
    private static func long(_ tag: Int, _ values: [Int]) -> Tag {
        Tag(tag: tag, type: 4, count: values.count, bytes: values.flatMap(le32))
    }
    private static func double(_ tag: Int, _ values: [Double]) -> Tag {
        Tag(tag: tag, type: 12, count: values.count, bytes: values.flatMap { le64($0.bitPattern) })
    }

    /// A classic little-endian TIFF: header, the directory at 8, its values, then `body`.
    private static func tiff(_ tags: (Int) -> [Tag], body: [UInt8]) -> [UInt8] {
        func build(_ bodyAt: Int) -> [UInt8] {
            let list = tags(bodyAt).sorted { $0.tag < $1.tag }
            let directorySize = 2 + list.count * 12 + 4
            var entries = le16(list.count), values: [UInt8] = []
            for tag in list {
                entries += le16(tag.tag) + le16(tag.type) + le32(tag.count)
                if tag.bytes.count <= 4 {
                    entries += tag.bytes + [UInt8](repeating: 0, count: 4 - tag.bytes.count)
                } else {
                    entries += le32(8 + directorySize + values.count)
                    values += tag.bytes
                }
            }
            var header: [UInt8] = [0x49, 0x49]
            header += le16(42)
            header += le32(8)
            return header + entries + le32(0) + values
        }
        return build(build(0).count) + body
    }

    /// 1 band of int16 in 1 tile, with the size and the placement given.
    private func file(
        width: Tag,
        height: Tag,
        tile: Int = 1,
        scale: [Double] = [1.0 / 3600, 1.0 / 3600, 0],
        tie: [Double] = [0, 0, 0, 30, 46, 0],
        extra: [Tag] = []
    ) throws -> URL {
        let bytes = Self.tiff(
            { at in
                [
                    width, height,
                    Self.short(TIFF.Tag.bitsPerSample, [16]), Self.short(TIFF.Tag.compression, [1]),
                    Self.short(TIFF.Tag.sampleFormat, [2]),
                    Self.short(TIFF.Tag.tileWidth, [tile]), Self.short(TIFF.Tag.tileLength, [tile]),
                    Self.long(TIFF.Tag.tileOffsets, [at]), Self.long(TIFF.Tag.tileByteCounts, [2 * tile * tile]),
                    Self.double(TIFF.Tag.modelPixelScale, scale), Self.double(TIFF.Tag.modelTiepoint, tie)
                ] + extra
            },
            body: [UInt8](repeating: 0x11, count: 2 * tile * tile)
        )
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("damaged-\(UUID().uuidString).tif")
        try FileTools.write(Data(bytes), to: url)
        addTeardownBlock { FileTools.removeIfPresent(url) }
        return url
    }

    func testAnOrdinaryFileOpens() throws {
        let url = try file(
            width: Self.short(TIFF.Tag.imageWidth, [2]),
            height: Self.short(TIFF.Tag.imageLength, [2]),
            tile: 2
        )
        XCTAssertEqual(try GeoTIFF(contentsOf: url).width, 2)
    }

    /// A size its single tile cannot hold: a row of it would be gigabytes.
    func testASizeNotItsTileGridsIsRefused() throws {
        for width in [Self.double(TIFF.Tag.imageWidth, [9e14]), Self.long(TIFF.Tag.imageWidth, [0xFFFF_FFFF])] {
            let url = try file(width: width, height: Self.short(TIFF.Tag.imageLength, [1]))
            XCTAssertThrowsError(try GeoTIFF(contentsOf: url))
        }
    }

    /// Placed off the globe: every figure made of it later would overflow.
    func testAPlacementOffTheGlobeIsRefused() throws {
        for (scale, tie) in [
            ([1e300, 1e300, 0.0], [0, 0, 0, 30, 47, 0.0]), ([1.0 / 1200, 1.0 / 1200, 0], [0, 0, 0, 1e17, 47, 0])
        ] {
            let url = try file(
                width: Self.short(TIFF.Tag.imageWidth, [1]),
                height: Self.short(TIFF.Tag.imageLength, [1]),
                scale: scale,
                tie: tie
            )
            XCTAssertThrowsError(try GeoTIFF(contentsOf: url))
        }
    }

    /// Tags the reader does not use are skipped, however many numbers they claim.
    func testTagsNotReadCostNothing() throws {
        let flood = (0..<50).map {
            Tag(tag: 40_000 + $0, type: 1, count: 1 << 20, bytes: [UInt8](repeating: 0, count: 8))
        }
        let url = try file(
            width: Self.short(TIFF.Tag.imageWidth, [1]),
            height: Self.short(TIFF.Tag.imageLength, [1]),
            extra: flood
        )
        let started = Date()
        XCTAssertNoThrow(try GeoTIFF(contentsOf: url))
        XCTAssertLessThan(Date().timeIntervalSince(started), 1)
    }

    // MARK: GEDTM30

    private func gedtm(
        width: Int,
        height: Int,
        tile: Int,
        tiles: Int,
        tie: [Double] = [0, 0, 0, 30, 47, 0]
    ) -> GEDTM30.Read {
        let bytes = Self.tiff(
            { at in
                [
                    Self.long(TIFF.Tag.imageWidth, [width]), Self.long(TIFF.Tag.imageLength, [height]),
                    Self.short(TIFF.Tag.bitsPerSample, [32]), Self.short(TIFF.Tag.compression, [8]),
                    Self.short(TIFF.Tag.sampleFormat, [3]),
                    Self.short(TIFF.Tag.tileWidth, [tile]), Self.short(TIFF.Tag.tileLength, [tile]),
                    Self.long(TIFF.Tag.tileOffsets, Array(repeating: at, count: tiles)),
                    Self.long(TIFF.Tag.tileByteCounts, Array(repeating: 0, count: tiles)),
                    Self.double(TIFF.Tag.modelPixelScale, [1.0 / 3600, 1.0 / 3600, 0]),
                    Self.double(TIFF.Tag.modelTiepoint, tie)
                ]
            },
            body: []
        )
        return { offset, count in
            guard offset >= 0, offset < Int64(bytes.count), count >= 0 else { return Data() }
            return Data(bytes[Int(offset)..<min(bytes.count, Int(offset) + count)])
        }
    }

    func testAGEDTMGridPastAnyGlobeIsRefused() async throws {
        do {
            _ = try await GEDTM30.layout(read: gedtm(width: 0xFFFF_FFFF, height: 0xFFFF_FFFF, tile: 1, tiles: 2))
            XCTFail("a grid of 2^64 tiles taken")
        } catch {}
    }

    func testAGEDTMTiepointOffTheGlobeIsRefused() async throws {
        do {
            _ = try await GEDTM30.layout(
                read: gedtm(width: 4, height: 4, tile: 2, tiles: 4, tie: [0.5, 0.5, 0, 1e300, 47, 0])
            )
            XCTFail("a tiepoint at 1e300 taken")
        } catch {}
        let sane = try await GEDTM30.layout(read: gedtm(width: 4, height: 4, tile: 2, tiles: 4))
        XCTAssertEqual(sane.width, 4)
    }
}
