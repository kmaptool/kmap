import XCTest

@testable import kmap

/// The share of a map its extracts hold is the share of its data, not of the ground its
/// tiles span: a map of Andorra and Monaco has tiles stretched over the south of France.
final class ImgDataShareTests: XCTestCase {
    private var directory = URL(fileURLWithPath: "/tmp")

    override func setUpWithError() throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("kmap-share-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private static func units(_ degrees: Double) -> Int { Int((degrees * Double(1 << 24) / 360).rounded()) }

    private static func put16(_ value: Int, into bytes: inout [UInt8]) {
        bytes += [UInt8(value & 0xFF), UInt8((value >> 8) & 0xFF)]
    }

    private static func put24(_ value: Int, into bytes: inout [UInt8]) {
        bytes += [UInt8(value & 0xFF), UInt8((value >> 8) & 0xFF), UInt8((value >> 16) & 0xFF)]
    }

    /// 1 tile: a coarse subdivision over the whole stretch from Andorra to Monaco, and at
    /// the detail level 900 RGN bytes in Andorra and 100 in Monaco.
    private func pairMap() throws -> URL {
        let headerLength = 0x31
        let levels: [UInt8] = [1, 22, 1, 0, 0, 24, 2, 0]
        var divisions: [UInt8] = []
        Self.put24(0, into: &divisions)
        // Coarse: centre between the 2, half a width of 2 degrees, no data of its own.
        divisions.append(0x40)
        Self.put24(Self.units(4.5), into: &divisions)
        Self.put24(Self.units(43.1), into: &divisions)
        Self.put16(Self.units(2) >> 2, into: &divisions)
        Self.put16(Self.units(0.7) >> 2, into: &divisions)
        Self.put16(0, into: &divisions)
        Self.put24(0, into: &divisions)
        // Detail: Andorra, then Monaco, each under 1 km across.
        for (lon, lat, end) in [(1.55, 42.55, 900), (7.42, 43.73, 1000)] {
            divisions.append(0x40)
            Self.put24(Self.units(lon), into: &divisions)
            Self.put24(Self.units(lat), into: &divisions)
            Self.put16(100, into: &divisions)
            Self.put16(100, into: &divisions)
            Self.put24(end, into: &divisions)
        }
        var tre = [UInt8](repeating: 0, count: headerLength)
        tre[0] = UInt8(headerLength)
        let levelsAt = headerLength, divisionsAt = headerLength + levels.count
        for (offset, value) in [
            (0x21, levelsAt), (0x25, levels.count), (0x29, divisionsAt), (0x2D, divisions.count)
        ] {
            for i in 0..<4 { tre[offset + i] = UInt8((value >> (8 * i)) & 0xFF) }
        }
        tre += levels
        tre += divisions
        return try ImgFixture.container([("63000001", "TRE", tre)], into: directory)
    }

    private let andorra = BBox(minLon: 1.4, minLat: 42.4, maxLon: 1.8, maxLat: 42.7)
    private let monaco = BBox(minLon: 7.40, minLat: 43.72, maxLon: 7.44, maxLat: 43.76)

    func testTheShareIsTheDataAnExtractHolds() throws {
        let img = try pairMap()
        let andorraOnly = try XCTUnwrap(ImgElements.dataShare(of: img, within: [andorra]))
        XCTAssertEqual(andorraOnly, 0.9, accuracy: 1e-9, "900 of the 1000 detail bytes")
        let both = try XCTUnwrap(ImgElements.dataShare(of: img, within: [andorra, monaco]))
        XCTAssertEqual(both, 1, accuracy: 1e-9, "the 2 extracts the map was built from hold all of it")
    }

    func testAnExtractBesideTheDataHoldsNone() throws {
        let img = try pairMap()
        let between = BBox(minLon: 4, minLat: 42.8, maxLon: 5, maxLat: 43.4)
        XCTAssertEqual(ImgElements.dataShare(of: img, within: [between]), 0, "ground the coarse level spans")
    }

    func testAMapWithNoTileHasNoShare() throws {
        let img = try ImgFixture.container([("63000001", "RGN", [UInt8](repeating: 0, count: 16))], into: directory)
        XCTAssertNil(ImgElements.dataShare(of: img, within: [andorra]))
    }
}
