import XCTest

@testable import kmap

/// Writing a PBF, and reading it back with kmap's own reader.
///
/// A round trip covers most of it. What a round trip cannot see -- the blob framing, the
/// deflate wrapper, how many blocks a batch was cut into -- is checked directly.
final class PBFWriterTests: XCTestCase {
    private var directory = URL(fileURLWithPath: "/tmp")

    override func setUpWithError() throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("kmap-writer-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func path(_ name: String = "out.osm.pbf") -> URL {
        directory.appendingPathComponent(name)
    }

    @discardableResult
    private func roundTrip(
        _ write: (PBFWriter) -> Void,
        file: URL? = nil
    ) throws -> CollectedElements {
        let url = file ?? path()
        let writer = try PBFWriter(to: url)
        writer.header()
        write(writer)
        try writer.finish()
        var collected = CollectedElements()
        try PBFReader(url: url).read(into: &collected)
        return collected
    }

    // MARK: Nodes

    func testANodeComesBackWhereItWasPut() throws {
        let out = try roundTrip {
            $0.nodes([PBFWriter.Node(id: 1, lat: 44.6166, lon: 33.5254, tags: [])])
        }
        XCTAssertEqual(out.nodes.count, 1)
        XCTAssertEqual(out.nodes[0].id, 1)
        // The format keeps coordinates to 1e-7 of a degree, about a centimetre.
        XCTAssertEqual(out.nodes[0].lat, 44.6166, accuracy: 1e-7)
        XCTAssertEqual(out.nodes[0].lon, 33.5254, accuracy: 1e-7)
    }

    func testCoordinatesSurviveEveryCornerOfTheWorld() throws {
        let places: [(Double, Double)] = [
            (0, 0), (90, 180), (-90, -180), (89.9999999, 179.9999999),
            (-33.8688, 151.2093), (78.2232, 15.6469), (-54.8019, -68.3030)
        ]
        let out = try roundTrip { writer in
            writer.nodes(
                places.enumerated().map { i, place in
                    PBFWriter.Node(id: Int64(i + 1), lat: place.0, lon: place.1, tags: [])
                }
            )
        }
        XCTAssertEqual(out.nodes.count, places.count)
        for (i, place) in places.enumerated() {
            XCTAssertEqual(out.nodes[i].lat, place.0, accuracy: 1e-7, "lat \(place)")
            XCTAssertEqual(out.nodes[i].lon, place.1, accuracy: 1e-7, "lon \(place)")
        }
    }

    func testNodesComeOutInIDOrderHoweverTheyWentIn() throws {
        let out = try roundTrip { writer in
            writer.nodes([
                PBFWriter.Node(id: 900, lat: 1, lon: 1, tags: []),
                PBFWriter.Node(id: 3, lat: 2, lon: 2, tags: []),
                PBFWriter.Node(id: 47, lat: 3, lon: 3, tags: [])
            ])
        }
        XCTAssertEqual(out.nodes.map(\.id), [3, 47, 900])
        // The coordinates must travel with their own node, not with the position.
        XCTAssertEqual(out.nodes[0].lat, 2, accuracy: 1e-7)
        XCTAssertEqual(out.nodes[2].lat, 1, accuracy: 1e-7)
    }

    func testNodeTagsSurviveIncludingRepeatsAndAlphabets() throws {
        let out = try roundTrip { writer in
            writer.nodes([
                PBFWriter.Node(
                    id: 1,
                    lat: 0,
                    lon: 0,
                    tags: [("barrier", "gate"), ("name", "Ливадия")]
                ),
                PBFWriter.Node(
                    id: 2,
                    lat: 0,
                    lon: 0,
                    tags: [("barrier", "gate")]
                ),  // same strings again
                PBFWriter.Node(id: 3, lat: 0, lon: 0, tags: [])
            ])
        }
        XCTAssertEqual(out.nodes[0].tags.map(\.0), ["barrier", "name"])
        XCTAssertEqual(out.nodes[0].tags.map(\.1), ["gate", "Ливадия"])
        XCTAssertEqual(out.nodes[1].tags.map(\.1), ["gate"])
        XCTAssertTrue(out.nodes[2].tags.isEmpty)
    }

    func testNegativeAndVeryLargeIDsSurvive() throws {
        // Contours are numbered from a high base, and repairs invent negative ids.
        let ids: [Int64] = [-5_000_000_000, -1, 1, 8_000_000_000_000, Int64.max / 4]
        let out = try roundTrip { writer in
            writer.nodes(ids.map { PBFWriter.Node(id: $0, lat: 0, lon: 0, tags: []) })
        }
        XCTAssertEqual(out.nodes.map(\.id), ids.sorted())
    }

    func testAnEmptyBatchWritesNothingAtAll() throws {
        let out = try roundTrip { writer in
            writer.nodes([])
            writer.ways([])
            writer.relations([])
        }
        XCTAssertTrue(out.nodes.isEmpty)
        XCTAssertTrue(out.ways.isEmpty)
        XCTAssertTrue(out.relations.isEmpty)
    }

    // MARK: Ways and relations

    func testAWayKeepsItsRefsInOrderIncludingRepeats() throws {
        let out = try roundTrip { writer in
            writer.ways([
                PBFWriter.Way(
                    id: 7,
                    refs: [5, 5, 900, 4, 900],
                    tags: [("highway", "track")]
                )
            ])
        }
        XCTAssertEqual(out.ways.count, 1)
        XCTAssertEqual(out.ways[0].refs, [5, 5, 900, 4, 900])
        XCTAssertEqual(out.ways[0].tags.map(\.0), ["highway"])
    }

    func testAClosedWayEndsOnTheNodeItStartedFrom() throws {
        let out = try roundTrip { writer in
            writer.ways([PBFWriter.Way(id: 1, refs: [10, 11, 12, 10], tags: [])])
        }
        XCTAssertEqual(out.ways[0].refs.first, out.ways[0].refs.last)
    }

    func testAWayWithNoTagsWritesNoTagFields() throws {
        let out = try roundTrip { writer in
            writer.ways([PBFWriter.Way(id: 1, refs: [1, 2], tags: [])])
        }
        XCTAssertTrue(out.ways[0].tags.isEmpty)
    }

    func testRelationMembersKeepTheirKindIDAndRole() throws {
        let members = [
            PBFWriter.Relation.Member(kind: 0, ref: 100, role: "admin_centre"),
            PBFWriter.Relation.Member(kind: 1, ref: 200, role: "outer"),
            PBFWriter.Relation.Member(kind: 2, ref: 300, role: "")
        ]
        let out = try roundTrip { writer in
            writer.relations([
                PBFWriter.Relation(
                    id: 9,
                    members: members,
                    tags: [("type", "multipolygon")]
                )
            ])
        }
        XCTAssertEqual(out.relations.count, 1)
        XCTAssertEqual(out.relations[0].kinds, [0, 1, 2])
        XCTAssertEqual(out.relations[0].ids, [100, 200, 300])
        XCTAssertEqual(out.relations[0].roles, ["admin_centre", "outer", ""])
        XCTAssertEqual(out.relations[0].tags.map(\.1), ["multipolygon"])
    }

    func testARelationWithNoMembersStillCarriesItsTags() throws {
        let out = try roundTrip { writer in
            writer.relations([
                PBFWriter.Relation(
                    id: 1,
                    members: [],
                    tags: [("type", "route")]
                )
            ])
        }
        XCTAssertEqual(out.relations[0].ids, [])
        XCTAssertEqual(out.relations[0].tags.map(\.1), ["route"])
    }

    func testNodesWaysAndRelationsInOneFileAllComeBack() throws {
        let out = try roundTrip { writer in
            writer.nodes([PBFWriter.Node(id: 1, lat: 1, lon: 1, tags: [])])
            writer.ways([PBFWriter.Way(id: 2, refs: [1], tags: [])])
            writer.relations([
                PBFWriter.Relation(
                    id: 3,
                    members: [.init(kind: 1, ref: 2, role: "outer")],
                    tags: []
                )
            ])
        }
        XCTAssertEqual(out.nodes.count, 1)
        XCTAssertEqual(out.ways.count, 1)
        XCTAssertEqual(out.relations.count, 1)
    }

    // MARK: Blocks

    func testABatchTooBigForOneBlockIsCutIntoSeveral() throws {
        // The per-block bound is sixteen thousand; the batch comes back whole regardless.
        let url = path("big.osm.pbf")
        let out = try roundTrip(
            { writer in
                writer.nodes(
                    (1...40_000).map {
                        PBFWriter.Node(
                            id: Int64($0),
                            lat: 45 + Double($0) * 1e-6,
                            lon: 33,
                            tags: []
                        )
                    }
                )
            },
            file: url
        )
        XCTAssertEqual(out.nodes.count, 40_000)
        XCTAssertEqual(out.nodes.first?.id, 1)
        XCTAssertEqual(out.nodes.last?.id, 40_000)
        XCTAssertGreaterThanOrEqual(try blobKinds(of: url).filter { $0 == "OSMData" }.count, 3)
    }

    func testTheHeaderIsTheFirstBlobAndTheOnlyOne() throws {
        let url = path("header.osm.pbf")
        try roundTrip(
            { $0.nodes([PBFWriter.Node(id: 1, lat: 0, lon: 0, tags: [])]) },
            file: url
        )
        let kinds = try blobKinds(of: url)
        XCTAssertEqual(kinds.first, "OSMHeader")
        XCTAssertEqual(kinds.filter { $0 == "OSMHeader" }.count, 1)
    }

    func testABoundingBoxIsWrittenAsTheFileSaysItCovers() throws {
        let url = path("bbox.osm.pbf")
        let writer = try PBFWriter(to: url)
        writer.header(
            bbox: (
                minLat: 44.1341, minLon: 32.1505,
                maxLat: 46.2812, maxLon: 36.6835
            )
        )
        writer.nodes([PBFWriter.Node(id: 1, lat: 45, lon: 33, tags: [])])
        try writer.finish()

        let box = try PBFReader(url: url).headerBBox()
        XCTAssertEqual(box?.minLat ?? 0, 44.1341, accuracy: 1e-9)
        XCTAssertEqual(box?.minLon ?? 0, 32.1505, accuracy: 1e-9)
        XCTAssertEqual(box?.maxLat ?? 0, 46.2812, accuracy: 1e-9)
        XCTAssertEqual(box?.maxLon ?? 0, 36.6835, accuracy: 1e-9)
    }

    func testABoundingBoxAcrossZeroAndTheEquatorSurvives() throws {
        let url = path("bbox0.osm.pbf")
        let writer = try PBFWriter(to: url)
        writer.header(bbox: (minLat: -1.5, minLon: -0.5, maxLat: 1.5, maxLon: 0.5))
        try writer.finish()
        let box = try PBFReader(url: url).headerBBox()
        XCTAssertEqual(box?.minLat ?? 0, -1.5, accuracy: 1e-9)
        XCTAssertEqual(box?.minLon ?? 0, -0.5, accuracy: 1e-9)
        XCTAssertEqual(box?.maxLon ?? 0, 0.5, accuracy: 1e-9)
    }

    func testFinishCanBeCalledTwiceWithoutHarm() throws {
        let url = path("twice.osm.pbf")
        let writer = try PBFWriter(to: url)
        writer.header()
        writer.nodes([PBFWriter.Node(id: 1, lat: 0, lon: 0, tags: [])])
        try writer.finish()
        let size = try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int
        try writer.finish()
        let after = try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int
        XCTAssertEqual(size, after)
    }

    func testAFileLargerThanTheFlushThresholdIsWrittenWhole() throws {
        // A megabyte is buffered before the writer touches the disk; this crosses that
        // several times over.
        let url = path("streamed.osm.pbf")
        let out = try roundTrip(
            { writer in
                for batch in 0..<12 {
                    writer.nodes(
                        (0..<20_000).map { i in
                            PBFWriter.Node(
                                id: Int64(batch * 20_000 + i + 1),
                                lat: 45 + Double(i) * 1e-5,
                                lon: 33,
                                tags: [("name", "node \(batch)-\(i)")]
                            )
                        }
                    )
                }
            },
            file: url
        )
        XCTAssertEqual(out.nodes.count, 240_000)
        XCTAssertEqual(out.nodes.last?.id, 240_000)
    }

    // MARK: Reading the blob framing by hand

    /// The kinds of every blob in the file, straight off the four-byte lengths.
    private func blobKinds(of url: URL) throws -> [String] {
        let data = try Data(contentsOf: url)
        var kinds: [String] = []
        var at = 0
        while at + 4 <= data.count {
            let length = Int(data[at..<(at + 4)].reduce(UInt32(0)) { $0 << 8 | UInt32($1) })
            at += 4
            guard at + length <= data.count else { break }
            var kind = ""
            var size = 0
            data.withUnsafeBytes { file in
                var reader = ProtoReader(UnsafeRawBufferPointer(rebasing: file[at..<(at + length)]))
                while let field = reader.nextField() {
                    switch field.number {
                    case 1: kind = String(decoding: reader.lengthDelimited(), as: UTF8.self)
                    case 3: size = Int(reader.varint())
                    default: reader.skip(wire: field.wire)
                    }
                }
            }
            kinds.append(kind)
            at += length + size
        }
        return kinds
    }

    // MARK: When the disk says no

    func testAWriteThatFailsIsReportedByFinishRatherThanCrashing() throws {
        // The handle is closed underneath the writer, which is what a full disk looks
        // like from here: the write throws, and the error comes out of finish.
        let writer = try PBFWriter(to: path("closed.osm.pbf"))
        writer.header()
        try writer.handle.close()
        writer.nodes((1...50_000).map { PBFWriter.Node(id: Int64($0), lat: 45, lon: 33, tags: [("name", "n\($0)")]) })
        XCTAssertThrowsError(try writer.finish())
    }

    #if os(Linux)
    func testAFullDiskIsReportedNotFatal() throws {
        let writer = try PBFWriter(to: URL(fileURLWithPath: "/dev/full"))
        writer.header()
        writer.nodes((1...50_000).map { PBFWriter.Node(id: Int64($0), lat: 45, lon: 33, tags: [("name", "n\($0)")]) })
        XCTAssertThrowsError(try writer.finish())
    }
    #endif
}
