import XCTest

@testable import kmap

/// The element reader against real maps, held to mkgmap's own reading of them.
///
/// Equivalence was established by comparing this reader's dump with one written by a
/// helper compiled against mkgmap: the two agreed byte for byte on a map kmap built
/// and on a third-party map carrying extended types. The dumps are too large to keep,
/// so the expectations are their counts and checksum. Maps and expectations are the
/// developer's own and live outside the repository; see `LocalTestMaps`.
final class RealMapReaderTests: XCTestCase {
    func testTheReaderStillReadsWhatMkgmapReads() throws {
        let expectations = LocalTestMaps.load()?.reader ?? []
        try XCTSkipUnless(!expectations.isEmpty, "no local map expectations")
        // The largest map is a gigabyte of dump and a minute in a debug build: read on
        // request, not on every run of the suite.
        let long = ProcessInfo.processInfo.environment["KMAP_LONG_TESTS"] != nil
        var seen = 0
        for map in (long ? expectations : Array(expectations.prefix(1))) {
            let url = URL(fileURLWithPath: map.path)
            guard FileTools.exists(url), map.ground.count == 4 else { continue }
            seen += 1

            let ground = BBox(
                minLon: map.ground[1],
                minLat: map.ground[0],
                maxLon: map.ground[3],
                maxLat: map.ground[2]
            )
            var dump = ElementDumper.Dump()
            try ImgElements.read(
                img: url,
                grounds: [ImgElements.Ground(ground)],
                extendedAreasAndPoints: false,
                tick: {}
            ) { kind, type, coords in
                let from = dump.cells.count
                for c in coords { dump.cells.append(GarminGrid.pack(latUnit: c.lat, lonUnit: c.lon)) }
                dump.elements.append(
                    ElementDumper.Element(
                        kind: kind,
                        type: type,
                        from: Int32(from),
                        count: Int32(coords.count)
                    )
                )
            }
            XCTAssertEqual(dump.count, map.elements, url.lastPathComponent)
            XCTAssertEqual(dump.cells.count, map.vertices, url.lastPathComponent)

            let file = FileManager.default.temporaryDirectory
                .appendingPathComponent("kmap-reader-\(UUID().uuidString).bin")
            defer { try? FileManager.default.removeItem(at: file) }
            try ElementDumper.write(dump, to: file)
            var digest = MD5()
            let handle = try FileHandle(forReadingFrom: file)
            defer { try? handle.close() }
            while let chunk = try handle.read(upToCount: 1 << 24), !chunk.isEmpty {
                chunk.withUnsafeBytes { digest.update($0) }
            }
            XCTAssertEqual(MD5.hex(digest.finalize()), map.md5, url.lastPathComponent)
        }
        try XCTSkipUnless(seen > 0, "none of the listed maps is on this machine")
    }

    func testRandomDamageToARealMapIsRefusedOrReadNeverFatal() throws {
        // Every offset in TRE and RGN comes from the file. The smallest local map, with
        // bytes replaced and stretches cut, must throw or read short, never trap.
        let maps = (LocalTestMaps.load()?.reader ?? []).map { URL(fileURLWithPath: $0.path) }
            .filter { FileTools.exists($0) && FileTools.size(of: $0) <= 32 << 20 }
        guard let smallest = maps.min(by: { FileTools.size(of: $0) < FileTools.size(of: $1) }) else {
            throw XCTSkip("no local map under 32 MB")
        }
        let whole = [UInt8](try Data(contentsOf: smallest))
        let folder = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("kmap-damage-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        var random = SplitMix64(state: 20_260_930)
        let planet = ImgElements.Ground(BBox(minLon: -180, minLat: -90, maxLon: 180, maxLat: 90))
        for i in 0..<120 {
            var bytes = whole
            for _ in 0...Int.random(in: 0...3, using: &random) {
                let at = Int.random(in: 0..<bytes.count, using: &random)
                switch Int.random(in: 0..<3, using: &random) {
                case 0: bytes[at] = UInt8.random(in: 0...255, using: &random)
                case 1: for k in at..<min(bytes.count, at + 16) { bytes[k] = 0xFF }
                default: bytes.removeSubrange(at..<min(bytes.count, at + Int.random(in: 1...4096, using: &random)))
                }
            }
            let url = folder.appendingPathComponent("damaged-\(i).img")
            try FileTools.write(Data(bytes), to: url)
            _ = try? ImgElements.read(img: url, grounds: [planet], extendedAreasAndPoints: true, tick: {}) { _, _, _ in
            }
        }
    }
}
