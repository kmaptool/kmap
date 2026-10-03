import XCTest

@testable import kmap

/// GEDTM30 is read a piece at a time out of 1 BigTIFF. These build a small one in memory
/// with the real layout (deflate, predictor 2, float32 tiles, PixelIsArea, nodata) and
/// check that every node lands on its pixel and that only the pieces needed are read.
final class GEDTM30Tests: XCTestCase {
    private let nodata: Float = 3.4e38
    private let width = 6, height = 6, tile = 4

    /// Pixel (row, column) holds row * 10 + column + 0.5, except a negative one and a hole.
    private func value(_ row: Int, _ column: Int) -> Float {
        if row == 3 && column == 1 { return nodata }
        if row == 2 && column == 2 { return -2.5 }
        return Float(row * 10 + column) + 0.5
    }

    /// A little-endian BigTIFF whose pixel (0, 0) is centred on 10E, 45N + 2 arc-seconds.
    private func file(sea: Bool = false) -> Data {
        var tiles: [[UInt8]] = []
        for tileRow in 0..<2 {
            for tileColumn in 0..<2 {
                var raw: [UInt8] = []
                for r in 0..<tile {
                    var previous: UInt32 = 0
                    for c in 0..<tile {
                        let row = tileRow * tile + r, column = tileColumn * tile + c
                        let v = sea ? nodata : (row < height && column < width ? value(row, column) : 0)
                        let word = v.bitPattern
                        raw += le(UInt64(word &- previous), 4)
                        previous = word
                    }
                }
                tiles.append(Deflate.deflate(raw)!)
            }
        }
        var body: [UInt8] = []
        var offsets: [UInt64] = []
        for t in tiles {
            offsets.append(UInt64(16 + body.count))
            body += t
        }
        func place(_ bytes: [UInt8]) -> UInt64 {
            let at = UInt64(16 + body.count)
            body += bytes
            return at
        }
        let offsetsAt = place(offsets.flatMap { le($0, 8) })
        let countsAt = place(tiles.flatMap { le(UInt64($0.count), 4) })
        let step = 1.0 / 3600
        let scaleAt = place([step, step, 0].flatMap { le($0.bitPattern, 8) })
        let tie = [0, 0, 0, 10 - step / 2, 45 + 2 * step + step / 2, 0]
        let tieAt = place(tie.flatMap { le($0.bitPattern, 8) })
        // (tag, type, count, value or offset)
        let nodataText = UInt64(littleEndianBytes: Array("3.4e38".utf8) + [0, 0])
        var entries: [(Int, Int, Int, UInt64)] = []
        entries.append((256, 3, 1, UInt64(width)))
        entries.append((257, 3, 1, UInt64(height)))
        entries.append((258, 3, 1, 32))
        entries.append((259, 3, 1, 8))
        entries.append((277, 3, 1, 1))
        entries.append((317, 3, 1, 2))
        entries.append((322, 3, 1, UInt64(tile)))
        entries.append((323, 3, 1, UInt64(tile)))
        entries.append((324, 16, 4, offsetsAt))
        entries.append((325, 4, 4, countsAt))
        entries.append((339, 3, 1, 3))
        entries.append((33550, 12, 3, scaleAt))
        entries.append((33922, 12, 6, tieAt))
        entries.append((42113, 2, 7, nodataText))
        let ifd = UInt64(16 + body.count)
        var out: [UInt8] = [0x49, 0x49]
        out += le(43, 2)
        out += le(8, 2)
        out += le(0, 2)
        out += le(ifd, 8)
        out += body
        out += le(UInt64(entries.count), 8)
        for (tag, type, count, field) in entries {
            out += le(UInt64(tag), 2)
            out += le(UInt64(type), 2)
            out += le(UInt64(count), 8)
            out += le(field, 8)
        }
        out += le(0, 8)
        return Data(out)
    }

    private func le(_ value: UInt64, _ width: Int) -> [UInt8] {
        (0..<width).map { UInt8(truncatingIfNeeded: value >> (8 * UInt64($0))) }
    }

    /// Reads out of `data`, noting every range asked.
    private func reader(_ data: Data, asked: Locked<[(Int64, Int)]>) -> GEDTM30.Read {
        { offset, count in
            asked.withLock { $0.append((offset, count)) }
            let from = Int(offset), to = min(data.count, from + count)
            return data.subdata(in: from..<to)
        }
    }

    private var source: GEDTM30 {
        var source = GEDTM30.v12
        source.nodes = 3
        return source
    }

    func testTheLayoutIsReadFromTheHeaderAndTheTagsAlone() async throws {
        let asked = Locked<[(Int64, Int)]>([])
        let layout = try await GEDTM30.layout(read: reader(file(), asked: asked))
        XCTAssertEqual(layout.width, 6)
        XCTAssertEqual(layout.tilesAcross, 2)
        XCTAssertEqual(layout.tileCount, 4)
        XCTAssertEqual(layout.offsetSize, 8)
        XCTAssertEqual(layout.countSize, 4)
        XCTAssertEqual(layout.firstLon, 10, accuracy: 1e-9, "the pixel's centre, not its corner")
        XCTAssertEqual(layout.nodata, nodata)
        // Nothing of the tiles or of the index entries is read for this.
        let tileBytes = asked.withLock { $0 }.filter { $0.0 >= 16 && $0.0 < 16 + 40 }
        XCTAssertTrue(tileBytes.isEmpty)
    }

    func testANodeIsThePixelCentredOnIt() async throws {
        let layout = try await GEDTM30.layout(read: reader(file(), asked: Locked([])))
        // The cell's north-west node is 45N 10E: row 2, column 0.
        let corner = try layout.corner(lat: 44, lon: 10)
        XCTAssertEqual(corner.row, 2)
        XCTAssertEqual(corner.column, 0)
        // Rows 2 to 4 cross into the second row of tiles; columns 0 to 2 stay in the first.
        XCTAssertEqual(try layout.tiles(lat: 44, lon: 10, nodes: 3), [0, 2])
        XCTAssertEqual(try layout.tiles(lat: -30, lon: 140, nodes: 3), [], "off the raster")
        // Rows 4 to 6 of a raster of 6: cut by its south edge, so left to later sources.
        XCTAssertEqual(try layout.tiles(lat: 44, lon: 10, nodes: 5), [])
    }

    func testTheIndexIsReadOnlyAroundTheTilesWanted() async throws {
        XCTAssertEqual(GEDTM30.runs(of: [500, 1, 3, 2, 100]), [[1, 2, 3], [100], [500]])
        XCTAssertEqual(GEDTM30.runs(of: [0, 64]), [[0, 64]], "a gap of 64 entries is read through")
        let asked = Locked<[(Int64, Int)]>([])
        let read = reader(file(), asked: asked)
        let layout = try await GEDTM30.layout(read: read)
        asked.withLock { $0 = [] }
        let spans = try await GEDTM30.spans(of: [2], in: layout, read: read)
        XCTAssertEqual(Set(spans.keys), [2])
        // 1 offset of 8 bytes and 1 count of 4, nothing either side.
        XCTAssertEqual(asked.withLock { $0 }.map(\.1).sorted(), [4, 8])
    }

    func testTheCellIsWrittenNodeByNodeWithTheHoleLeftAtZero() async throws {
        let data = file()
        let read = reader(data, asked: Locked([]))
        let layout = try await GEDTM30.layout(read: read)
        let spans = try await GEDTM30.spans(of: [0, 2], in: layout, read: read)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("gedtm-\(UUID()).hgt")
        defer { FileTools.removeIfPresent(url) }
        let ground = try source.write(lat: 44, lon: 10, layout: layout, to: url) { tile in
            guard let span = spans[tile] else { return nil }
            let from = Int(span.offset)
            return try GEDTM30.decode(data.subdata(in: from..<(from + span.count)), layout: layout)
        }
        XCTAssertEqual(ground, 8, "9 nodes, 1 of them nodata")
        let bytes = try [UInt8](Data(contentsOf: url))
        let heights = (0..<9).map { Int16(bitPattern: UInt16(bytes[$0 * 2]) << 8 | UInt16(bytes[$0 * 2 + 1])) }
        // Rows 2 to 4, columns 0 to 2; x.5 rounds away from zero.
        XCTAssertEqual(heights, [21, 22, -3, 31, 0, 33, 41, 42, 43])
    }

    func testACellOfNodataIsSeaAndWritesNothing() async throws {
        let data = file(sea: true)
        let read = reader(data, asked: Locked([]))
        let layout = try await GEDTM30.layout(read: read)
        let spans = try await GEDTM30.spans(of: [0, 2], in: layout, read: read)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("gedtm-\(UUID()).hgt")
        let ground = try source.write(lat: 44, lon: 10, layout: layout, to: url) { tile in
            let span = spans[tile]!
            let from = Int(span.offset)
            return try GEDTM30.decode(data.subdata(in: from..<(from + span.count)), layout: layout)
        }
        XCTAssertEqual(ground, 0)
        XCTAssertFalse(FileTools.exists(url))
    }

    func testARangeAnsweredFromElsewhereIsRefused() {
        XCTAssertTrue(RangeSession.serves("bytes 100-199/1000", asked: "bytes=100-199"))
        XCTAssertTrue(RangeSession.serves("bytes 100-999/1000", asked: "bytes=100-"))
        XCTAssertFalse(RangeSession.serves("bytes 0-99/1000", asked: "bytes=100-199"))
        XCTAssertTrue(RangeSession.serves("", asked: "bytes=100-199"), "unreadable is taken on trust")
    }
}

private extension UInt64 {
    init(littleEndianBytes bytes: [UInt8]) {
        self = bytes.prefix(8).enumerated().reduce(0) { $0 | UInt64($1.element) << (8 * UInt64($1.offset)) }
    }
}
