import XCTest

@testable import kmap

/// The census is what a run did not see: every code a map draws off the ground read,
/// subdivision by subdivision.
final class ImgCensusTests: XCTestCase {
    private var directory = URL(fileURLWithPath: "/tmp")

    override func setUpWithError() throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("kmap-census-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    /// 2 subdivisions 2 degrees apart: 3 points in the west one, 1 of them 1000 map units
    /// east of its middle, and 3 of another code in the east one.
    private static let detail: [TreFixture.Detail] = [
        .init(
            lon: 10.5,
            lat: 50.5,
            halfLon: 0.2,
            halfLat: 0.2,
            points: [.init(type: 0x2a), .init(type: 0x2a, dLon: 1000), .init(type: 0x2b, dLon: -1000)]
        ),
        .init(
            lon: 12.5,
            lat: 50.5,
            halfLon: 0.2,
            halfLat: 0.2,
            points: [.init(type: 0x64), .init(type: 0x64, dLat: 500), .init(type: 0x64, dLat: -500)]
        )
    ]

    private func map(rgn: Bool = true) throws -> URL {
        let tre = TreFixture.tre(bounds: BBox(minLon: 10, minLat: 50, maxLon: 13, maxLat: 51), detail: Self.detail)
        var files = [("63000001", "TRE", tre)]
        if rgn { files.append(("63000001", "RGN", TreFixture.rgn(detail: Self.detail))) }
        return try ImgFixture.container(files, into: directory)
    }

    private func slot(_ type: Int) -> Int { Evidence.slot(.point, type) }

    private func census(off grounds: [BBox]) throws -> [ImgElements.Tally] {
        try census(off: grounds.map { ImgElements.Ground($0) })
    }

    private func census(off grounds: [ImgElements.Ground]) throws -> [ImgElements.Tally] {
        try ImgElements.census(of: try map(), off: grounds, stop: StopFlag()).sorted { $0.box.minLon < $1.box.minLon }
    }

    /// The same points as a reading of the grounds sees them, by code.
    private func reading(_ grounds: [ImgElements.Ground]) throws -> [Int: Int] {
        var seen: [Int: Int] = [:]
        try ImgElements.read(img: try map(), grounds: grounds, extendedAreasAndPoints: true, tick: {}) {
            (kind: ElementDumper.Kind, type: Int, _: [ImgElements.Coord]) in
            seen[Evidence.slot(kind, type), default: 0] += 1
        }
        return seen
    }

    private func region(_ rings: [[(lon: Double, lat: Double)]]) -> Region {
        let boxes = rings.map { ring -> BBox in
            var box = BBox.empty
            for vertex in ring { box.extend(lon: vertex.lon, lat: vertex.lat) }
            return box
        }
        var all = BBox.empty
        for box in boxes {
            all.extend(lon: box.minLon, lat: box.minLat)
            all.extend(lon: box.maxLon, lat: box.maxLat)
        }
        return Region(id: "r", name: "r", parentID: nil, pbfURL: nil, bbox: all, boxes: boxes, rings: rings)
    }

    /// A ground with an outline holds what the outline holds, however wide its rectangle:
    /// a subdivision inside it whole, one outside it not at all, and one across its edge
    /// point by point.
    func testAGroundIsCutToItsOutline() throws {
        let wide = BBox(minLon: 9, minLat: 49, maxLon: 14, maxLat: 52)
        // All of the west subdivision; of the east one, the ground south of 50.5 deg, which
        // holds the point 500 units south of its middle only.
        let outline = region([[(9, 49), (11, 49), (11, 52), (9, 52)], [(12, 50), (13, 50), (13, 50.499), (12, 50.499)]])
        let ground = ImgElements.Ground(wide, outline: outline)
        XCTAssertEqual(try reading([ground]), [slot(0x2a00): 2, slot(0x2b00): 1, slot(0x6400): 1])
        let off = try census(off: [ground])
        XCTAssertEqual(off.count, 1)
        XCTAssertEqual(off[0].codes, [slot(0x6400): 2])
        // The rectangle alone holds all 6 points.
        XCTAssertEqual(try reading([ImgElements.Ground(wide)]).values.reduce(0, +), 6)
        XCTAssertTrue(try census(off: [ImgElements.Ground(wide)]).isEmpty)
    }

    /// A subdivision beside 180 deg holds a point east of it, past the end of the scale:
    /// the ground west of 180 deg reads it, with an outline or without.
    func testAPointPast180LiesOnTheGroundWestOfIt() throws {
        let detail: [TreFixture.Detail] = [
            .init(
                lon: 179.9,
                lat: 50.5,
                halfLon: 0.2,
                halfLat: 0.2,
                points: [.init(type: 0x2a), .init(type: 0x2b, dLon: TreFixture.units(0.15))]
            )
        ]
        let bounds = BBox(minLon: 179, minLat: 50, maxLon: 181, maxLat: 51)
        let img = try ImgFixture.container(
            [
                ("63000001", "TRE", TreFixture.tre(bounds: bounds, detail: detail)),
                ("63000001", "RGN", TreFixture.rgn(detail: detail))
            ],
            into: directory
        )
        var cells: [Int: UInt64] = [:]
        func reading(_ grounds: [ImgElements.Ground]) throws -> [Int: Int] {
            var seen: [Int: Int] = [:]
            try ImgElements.read(img: img, grounds: grounds, extendedAreasAndPoints: true, tick: {}) {
                (kind: ElementDumper.Kind, type: Int, coords: [ImgElements.Coord]) in
                seen[Evidence.slot(kind, type), default: 0] += 1
                cells[type] = GarminGrid.pack(latUnit: coords[0].lat, lonUnit: coords[0].lon)
            }
            return seen
        }
        let east = BBox(minLon: 179, minLat: 50, maxLon: 180, maxLat: 51)
        let west = BBox(minLon: -180, minLat: 50, maxLon: -179, maxLat: 51)
        XCTAssertEqual(try reading([ImgElements.Ground(east)]), [slot(0x2a00): 1])
        XCTAssertEqual(try reading([ImgElements.Ground(west)]), [slot(0x2b00): 1])
        // Handed over where the ground has it: the cell of the same spot west of 180 deg,
        // which is what an extract's node there is matched by.
        let spot = ImgElements.Coord(
            lat: Int32(TreFixture.units(50.5)),
            lon: Int32(TreFixture.units(179.9) + TreFixture.units(0.15) - (1 << 24))
        )
        XCTAssertEqual(cells[0x2b00], GarminGrid.pack(latUnit: spot.lat, lonUnit: spot.lon))
        XCTAssertLessThan(spot.lon, 0)
        let outline = region([
            [(179, 50), (180, 50), (180, 51), (179, 51)], [(-180, 50), (-179, 50), (-179, 51), (-180, 51)]
        ])
        XCTAssertEqual(try reading([ImgElements.Ground(west, outline: outline)]), [slot(0x2b00): 1])
        XCTAssertEqual(
            try reading([ImgElements.Ground(east, outline: outline), ImgElements.Ground(west, outline: outline)]),
            [slot(0x2a00): 1, slot(0x2b00): 1]
        )
        // What the west ground read is not counted off it.
        let off = try ImgElements.census(of: img, off: [ImgElements.Ground(west)], stop: StopFlag())
        XCTAssertEqual(off.map(\.codes), [[slot(0x2a00): 1]])
        XCTAssertTrue(
            try ImgElements.census(
                of: img,
                off: [ImgElements.Ground(east, outline: outline), ImgElements.Ground(west, outline: outline)],
                stop: StopFlag()
            ).isEmpty
        )
    }

    /// The same from the other side: a point west of -180 deg lies on the ground east of
    /// 180 deg.
    func testAPointPastMinus180LiesOnTheGroundEastOfIt() throws {
        let detail: [TreFixture.Detail] = [
            .init(
                lon: -179.9,
                lat: 50.5,
                halfLon: 0.2,
                halfLat: 0.2,
                points: [.init(type: 0x2a), .init(type: 0x2b, dLon: -TreFixture.units(0.15))]
            )
        ]
        let bounds = BBox(minLon: -181, minLat: 50, maxLon: -179, maxLat: 51)
        let img = try ImgFixture.container(
            [
                ("63000001", "TRE", TreFixture.tre(bounds: bounds, detail: detail)),
                ("63000001", "RGN", TreFixture.rgn(detail: detail))
            ],
            into: directory
        )
        var seen: [Int: Int32] = [:]
        let east = ImgElements.Ground(BBox(minLon: 179, minLat: 50, maxLon: 180, maxLat: 51))
        try ImgElements.read(img: img, grounds: [east], extendedAreasAndPoints: true, tick: {}) {
            (_: ElementDumper.Kind, type: Int, coords: [ImgElements.Coord]) in
            seen[type] = coords[0].lon
        }
        XCTAssertEqual(seen.keys.sorted(), [0x2b00])
        XCTAssertEqual(seen[0x2b00], Int32(TreFixture.units(-179.9) - TreFixture.units(0.15) + (1 << 24)))
    }

    /// An element wholly past 180 deg is brought round whole; one across it, or touching
    /// it from inside the scale, stays as drawn.
    func testOnlyAnElementWhollyPast180IsBroughtRound() {
        let half = Int32(1 << 23), turn = Int32(1 << 24)
        func lons(_ values: [Int32]) -> [Int32] {
            ImgElements.broughtRound(values.map { ImgElements.Coord(lat: 7, lon: $0) }).map(\.lon)
        }
        XCTAssertEqual(lons([half + 5, half + 9]), [half + 5 - turn, half + 9 - turn])
        XCTAssertEqual(lons([half, half + 9]), [-half, half + 9 - turn], "from the line on")
        XCTAssertEqual(lons([-half - 5, -half - 9]), [turn - half - 5, turn - half - 9])
        XCTAssertEqual(lons([half - 5, half + 9]), [half - 5, half + 9], "across the line")
        XCTAssertEqual(lons([half, half]), [half, half], "on the line")
        XCTAssertEqual(lons([100, 200]), [100, 200])
        XCTAssertEqual(lons([]), [])
    }

    /// A subdivision centred on 0 deg, 0 deg, a point in each quarter around it and 1 on
    /// it: every sign of latitude and longitude is read where it lies, and what a ground
    /// read is exactly what the census leaves out.
    func testGroundAroundTheOriginIsReadInEveryQuarter() throws {
        let detail: [TreFixture.Detail] = [
            .init(
                lon: 0,
                lat: 0,
                halfLon: 0.2,
                halfLat: 0.2,
                points: [
                    .init(type: 0x2a, dLon: 1000, dLat: 1000), .init(type: 0x2b, dLon: -1000, dLat: 1000),
                    .init(type: 0x2c, dLon: -1000, dLat: -1000), .init(type: 0x2d, dLon: 1000, dLat: -1000),
                    .init(type: 0x2e)
                ]
            )
        ]
        let bounds = BBox(minLon: -1, minLat: -1, maxLon: 1, maxLat: 1)
        let img = try ImgFixture.container(
            [
                ("63000001", "TRE", TreFixture.tre(bounds: bounds, detail: detail)),
                ("63000001", "RGN", TreFixture.rgn(detail: detail))
            ],
            into: directory
        )
        func reading(_ grounds: [ImgElements.Ground]) throws -> [Int: ImgElements.Coord] {
            var seen: [Int: ImgElements.Coord] = [:]
            try ImgElements.read(img: img, grounds: grounds, extendedAreasAndPoints: true, tick: {}) {
                (_: ElementDumper.Kind, type: Int, coords: [ImgElements.Coord]) in
                seen[type] = coords[0]
            }
            return seen
        }
        func off(_ grounds: [ImgElements.Ground]) throws -> [Int] {
            try ImgElements.census(of: img, off: grounds, stop: StopFlag()).flatMap(\.codes.keys).sorted()
        }
        // 1000 map units are 0.0215 deg.
        let quarters: [(BBox, Int, Int32, Int32)] = [
            (BBox(minLon: 0.01, minLat: 0.01, maxLon: 1, maxLat: 1), 0x2a00, 1000, 1000),
            (BBox(minLon: -1, minLat: 0.01, maxLon: -0.01, maxLat: 1), 0x2b00, -1000, 1000),
            (BBox(minLon: -1, minLat: -1, maxLon: -0.01, maxLat: -0.01), 0x2c00, -1000, -1000),
            (BBox(minLon: 0.01, minLat: -1, maxLon: 1, maxLat: -0.01), 0x2d00, 1000, -1000)
        ]
        let all = [0x2a00, 0x2b00, 0x2c00, 0x2d00, 0x2e00]
        for (box, type, lon, lat) in quarters {
            let read = try reading([ImgElements.Ground(box)])
            XCTAssertEqual(read.keys.sorted(), [type])
            XCTAssertEqual(read[type]?.lon, lon)
            XCTAssertEqual(read[type]?.lat, lat)
            XCTAssertEqual(try off([ImgElements.Ground(box)]), all.filter { $0 != type }.map(slot))
        }
        // The point on 0 deg, 0 deg itself, and a ground no wider than it.
        let origin = try reading([ImgElements.Ground(BBox(minLon: 0, minLat: 0, maxLon: 0, maxLat: 0))])
        XCTAssertEqual(origin.keys.sorted(), [0x2e00])
        XCTAssertEqual(origin[0x2e00]?.lon, 0)
        XCTAssertEqual(origin[0x2e00]?.lat, 0)
        XCTAssertEqual(try reading([ImgElements.Ground(bounds)]).count, 5)
        XCTAssertTrue(try off([ImgElements.Ground(bounds)]).isEmpty)
        // An outline over the west half, across the equator, in a rectangle over all of it.
        let west = region([[(-1, -1), (-0.01, -1), (-0.01, 1), (-1, 1)]])
        let ground = ImgElements.Ground(bounds, outline: west)
        XCTAssertEqual(try reading([ground]).keys.sorted(), [0x2b00, 0x2c00])
        XCTAssertEqual(try off([ground]), [0x2a00, 0x2d00, 0x2e00].map(slot))
    }

    func testEverySubdivisionIsTalliedByCode() throws {
        let all = try census(off: [BBox]())
        XCTAssertEqual(all.count, 2)
        XCTAssertEqual(all[0].codes, [slot(0x2a00): 2, slot(0x2b00): 1])
        XCTAssertEqual(all[1].codes, [slot(0x6400): 3])
        XCTAssertEqual(all[0].box.minLon, 10.3, accuracy: 1e-4)
        XCTAssertEqual(all[0].box.maxLat, 50.7, accuracy: 1e-4)
        XCTAssertEqual(all[1].box.maxLon, 12.7, accuracy: 1e-4)
    }

    /// What lies on the ground a run read was seen by the run: the census leaves it out.
    func testElementsOnTheGroundReadAreLeftOut() throws {
        let west = BBox(minLon: 10.3, minLat: 50.3, maxLon: 10.7, maxLat: 50.7)
        let off = try census(off: [west])
        XCTAssertEqual(off.count, 1, "nothing of the west subdivision is off the ground")
        XCTAssertEqual(off[0].codes, [slot(0x6400): 3])
        // 1000 map units are 0.0215 deg: only that point lies on this ground.
        let sliver = BBox(minLon: 10.51, minLat: 50.4, maxLon: 10.6, maxLat: 50.6)
        let around = try census(off: [sliver])
        XCTAssertEqual(around.count, 2)
        XCTAssertEqual(around[0].codes, [slot(0x2a00): 1, slot(0x2b00): 1])
    }

    func testACodeKeepsItsSecondByte() throws {
        let detail: [TreFixture.Detail] = [
            .init(
                lon: 10.5,
                lat: 50.5,
                halfLon: 0.2,
                halfLat: 0.2,
                points: [.init(type: 0x2f, sub: 0x01), .init(type: 0x2f)]
            )
        ]
        let img = try ImgFixture.container(
            [
                (
                    "63000001", "TRE",
                    TreFixture.tre(bounds: BBox(minLon: 10, minLat: 50, maxLon: 11, maxLat: 51), detail: detail)
                ),
                ("63000001", "RGN", TreFixture.rgn(detail: detail))
            ],
            into: directory
        )
        let all = try ImgElements.census(of: img, off: [], stop: StopFlag())
        XCTAssertEqual(all.first?.codes, [slot(0x2f01): 1, slot(0x2f00): 1])
    }

    func testAStopIsACancellation() throws {
        let stop = StopFlag()
        stop.raise()
        XCTAssertThrowsError(try ImgElements.census(of: try map(), off: [], stop: stop)) {
            XCTAssertTrue($0 is CancellationError, "\($0)")
        }
    }

    /// A tile with no drawing to read is left out, not an error: the census is advice.
    func testATileThatDoesNotReadIsLeftOut() throws {
        XCTAssertTrue(try ImgElements.census(of: try map(rgn: false), off: [], stop: StopFlag()).isEmpty)
    }

    func testASlotNamesItsCode() {
        for (kind, type) in [(ElementDumper.Kind.point, 0x2f01), (.line, 0x16), (.area, 0x10f1d)] {
            let code = Evidence.code(ofSlot: Evidence.slot(kind, type))
            XCTAssertEqual(code?.kind, kind)
            XCTAssertEqual(code?.type, type)
        }
        XCTAssertNil(Evidence.code(ofSlot: 7 << 32))
    }
}
