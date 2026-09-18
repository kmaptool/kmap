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

            let ground = BBox(minLon: map.ground[1], minLat: map.ground[0],
                              maxLon: map.ground[3], maxLat: map.ground[2])
            var dump = ElementDumper.Dump()
            try ImgElements.read(img: url, grounds: [ImgElements.Ground(ground)],
                                 extendedAreasAndPoints: false, tick: {}) { kind, type, coords in
                let from = dump.cells.count
                for c in coords { dump.cells.append(GarminGrid.pack(latUnit: c.lat, lonUnit: c.lon)) }
                dump.elements.append(ElementDumper.Element(kind: kind, type: type,
                                                           from: Int32(from),
                                                           count: Int32(coords.count)))
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
}
