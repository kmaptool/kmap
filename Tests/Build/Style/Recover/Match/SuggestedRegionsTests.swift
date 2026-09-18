import XCTest
@testable import kmap

/// Which download the screen offers when nothing on the machine matches a map.
///
/// The rule under test: ground the map draws on, never ground its frame merely reaches.
/// A style's codes recur everywhere it draws, so one region inside the map answers for all.
final class SuggestedRegionsTests: XCTestCase {

    private func index() throws -> RegionIndex {
        func feature(_ id: String, _ parent: String?, box: [Double]) -> String {
            let parentLine = parent.map { "\"parent\": \"\($0)\"," } ?? ""
            return """
            {"properties": {"id": "\(id)", "name": "\(id)", \(parentLine)
              "urls": {"pbf": "https://example.org/\(id).osm.pbf"}},
             "geometry": {"coordinates": [[[\(box[0]), \(box[1])], [\(box[2]), \(box[1])],
                                           [\(box[2]), \(box[3])], [\(box[0]), \(box[3])]]]}}
            """
        }
        // Two rings, one either side of the 180th meridian: the single surrounding
        // box spans the globe.
        let antimeridian = """
        {"properties": {"id": "antimeridian", "name": "antimeridian",
          "urls": {"pbf": "https://example.org/antimeridian.osm.pbf"}},
         "geometry": {"coordinates": [
            [[[-180, 51], [-130, 51], [-130, 71], [-180, 71]]],
            [[[172, 51], [180, 51], [180, 71], [172, 71]]]]}}
        """
        let json = """
        {"features": [
          \(feature("continent", nil, box: [19, 41, 180, 82])),
          \(feature("coastal", "continent", box: [32, 44, 37, 46.5])),
          \(feature("exclave", "continent", box: [19.41, 54.32, 22.89, 55.39])),
          \(feature("inland", "continent", box: [27, 56, 36, 62])),
          \(feature("south", "continent", box: [36, 43, 50, 51])),
          \(feature("neighbour", nil, box: [23.3, 57.5, 28.2, 59.7])),
          \(antimeridian)
        ]}
        """
        let out = RegionIndex()
        try out.parse(Data(json.utf8))
        return out
    }

    /// A map drawn evenly over the given rectangles, each spot weighted by its area.
    private func drawn(_ boxes: [[Double]]) -> RegionSuggestion.DrawnGround {
        var frame = BBox.empty
        let spots = boxes.map { b -> RegionSuggestion.DrawnGround.Spot in
            let box = BBox(minLon: b[0], minLat: b[1], maxLon: b[2], maxLat: b[3])
            frame.extend(lon: box.minLon, lat: box.minLat)
            frame.extend(lon: box.maxLon, lat: box.maxLat)
            return RegionSuggestion.DrawnGround.Spot(box: box, weight: box.squareDegrees)
        }
        return RegionSuggestion.DrawnGround(spots: spots, frame: frame)
    }

    func testAMapTheSizeOfOneRegionGetsThatRegion() throws {
        let ground = drawn([[33, 44.3, 36.6, 46.2]])
        let offered = RegionSuggestion.suggestedRegions(on: ground, index: try index())
        XCTAssertEqual(offered.first?.region.id, "coastal")
        XCTAssertFalse(offered.contains { $0.region.id == "continent" }, "no continents on offer")
    }

    func testAContinentWideMapIsOfferedCountriesInsideIt() throws {
        let europe = drawn([[19, 41, 60, 70]])
        let offered = RegionSuggestion.suggestedRegions(on: europe, index: try index())
        XCTAssertFalse(offered.isEmpty)
        XCTAssertFalse(offered.contains { $0.region.hasChildren },
                       "a region with children is a region big enough to have them")
        // Candidates are ordered by drawn weight; the pick between them is made later,
        // on file size.
        XCTAssertEqual(offered.first?.region.id, "south")
        XCTAssertTrue(offered.contains { $0.region.id == "exclave" })
        for candidate in offered {
            XCTAssertTrue(candidate.isInside, "\(candidate.region.id) is not map ground")
        }
    }

    /// Ground is what the tiles cover, not what the frame reaches: one far tile drags
    /// the frame across a neighbour that has nothing drawn under it.
    func testAFrameSwollenByAFarTileDoesNotOfferTheCountriesInBetween() throws {
        let ground = drawn([
            [19.5, 54.3, 23, 55.5],   // the far tile
            [27, 56, 36, 62],         // the map's real mass
        ])
        let offered = RegionSuggestion.suggestedRegions(on: ground, index: try index())
        XCTAssertEqual(offered.first?.region.id, "inland",
                       "the region the map is made of, not the neighbour in the frame")
        XCTAssertTrue(offered.contains { $0.region.id == "exclave" },
                      "the far tile is real ground too")
        XCTAssertFalse(offered.contains { $0.region.id == "neighbour" },
                       "inside the frame, under no tile, nothing drawn there")
    }

    /// A map claiming a hair more ground than its own extract has (54.27 against 54.32):
    /// strict containment falls through to a region whose box spans the globe.
    func testAMapOvershootingItsRegionStillGetsThatRegion() throws {
        let ground = drawn([[19.56, 54.27, 22.90, 55.42]])
        let offered = RegionSuggestion.suggestedRegions(on: ground, index: try index())
        XCTAssertEqual(offered.map(\.region.id), ["exclave"])
    }

    func testAnAntimeridianRegionCoversOnlyItsOwnGround() throws {
        // A frame inside one ring matches the region; a frame the globe-spanning box
        // would otherwise swallow does not.
        let farSide = drawn([[-160, 60, -150, 65]])
        XCTAssertEqual(
            RegionSuggestion.suggestedRegions(on: farSide, index: try index())
                .map(\.region.id),
            ["antimeridian"])
        let border = drawn([[19.56, 54.27, 22.90, 55.42]])
        XCTAssertFalse(
            RegionSuggestion.suggestedRegions(on: border, index: try index())
                .contains { $0.region.id == "antimeridian" })
    }

    func testAMapOverlappingSeveralRegionsIsOfferedThemAsAlternatives() throws {
        // Reaches past the index and across two regions: the offer is the ones it
        // draws in.
        let ground = drawn([[10, 43, 40, 50]])
        let offered = RegionSuggestion.suggestedRegions(on: ground, index: try index())
        XCTAssertTrue(offered.allSatisfy { !$0.region.hasChildren }, "no continents in the offer")
        XCTAssertTrue(offered.contains { $0.region.id == "coastal" })
        XCTAssertTrue(offered.contains { $0.region.id == "south" })
    }

    /// A tile rectangle overlapping a neighbour carries almost no weight, so the
    /// neighbour is not ground.
    func testABorderTileDoesNotMakeANeighbourIntoGround() throws {
        var frame = BBox.empty
        var spots: [RegionSuggestion.DrawnGround.Spot] = []
        for (b, weight) in [([27.0, 56.0, 36.0, 62.0], 1000.0),    // the map's mass
                            ([26.8, 57.0, 27.5, 60.0], 2.0)] {     // a thin border tile
            let box = BBox(minLon: b[0], minLat: b[1], maxLon: b[2], maxLat: b[3])
            frame.extend(lon: box.minLon, lat: box.minLat)
            frame.extend(lon: box.maxLon, lat: box.maxLat)
            spots.append(RegionSuggestion.DrawnGround.Spot(box: box, weight: weight))
        }
        let offered = RegionSuggestion.suggestedRegions(
            on: RegionSuggestion.DrawnGround(spots: spots, frame: frame), index: try index())
        XCTAssertEqual(offered.first?.region.id, "inland")
        XCTAssertFalse(offered.contains { $0.region.id == "neighbour" },
                       "a corner of the neighbour sits under tiles, and none of the map's data does")
    }

    /// The offer is the lightest extract that still holds enough of the map's data.
    func testTheOfferIsTheLightestDownloadWithEnoughOfTheMapInIt() throws {
        let all = try index()
        func region(_ id: String) throws -> Region { try XCTUnwrap(all.region(id)) }
        func standing(_ id: String, inside: Double, drawnMB: Double) throws
        -> RegionSuggestion.Candidate {
            RegionSuggestion.Candidate(region: try region(id), inside: inside, share: 0.5,
                                    density: 1, drawn: drawnMB * 1_048_576)
        }
        let weighed: [(RegionSuggestion.Candidate, Int64)] = [
            (try standing("continent", inside: 1, drawnMB: 3000), 35_000_000_000),
            (try standing("coastal", inside: 1, drawnMB: 30), 180 * 1024 * 1024),
            (try standing("south", inside: 1, drawnMB: 270), 900 * 1024 * 1024),
        ]
        XCTAssertEqual(RegionSuggestion.worthDownloading(weighed)?.region.id, "coastal",
                       "thirty megabytes of the map is enough, and it is the lightest file")

        // When nothing clears the floor, the region holding the most of the map wins.
        let tiny: [(RegionSuggestion.Candidate, Int64)] = [
            (try standing("coastal", inside: 1, drawnMB: 2), 3 * 1024 * 1024),
            (try standing("exclave", inside: 1, drawnMB: 18), 20 * 1024 * 1024),
        ]
        XCTAssertEqual(RegionSuggestion.worthDownloading(tiny)?.region.id, "exclave")

        // The region the map is made of holds less than a neighbour it merely touches;
        // ground wins.
        let border: [(RegionSuggestion.Candidate, Int64)] = [
            (try standing("exclave", inside: 0.96, drawnMB: 18), 40 * 1024 * 1024),
            (try standing("south", inside: 0.2, drawnMB: 90), 90 * 1024 * 1024),
        ]
        XCTAssertEqual(RegionSuggestion.worthDownloading(border)?.region.id, "exclave")

        // The floor is on what the download buys, not on what it costs.
        let thin: [(RegionSuggestion.Candidate, Int64)] = [
            (try standing("coastal", inside: 1, drawnMB: 6), 180 * 1024 * 1024),
            (try standing("south", inside: 1, drawnMB: 150), 250 * 1024 * 1024),
        ]
        XCTAssertEqual(RegionSuggestion.worthDownloading(thin)?.region.id, "south")
    }

    func testTheDownloadLandsWhereABuildLooks() throws {
        let coastal = try XCTUnwrap(index().region("coastal"))
        XCTAssertEqual(RegionSuggestion.cacheDestination(for: coastal).lastPathComponent,
                       "coastal.osm.pbf")
        XCTAssertEqual(RegionSuggestion.cacheDestination(for: coastal)
            .deletingLastPathComponent(), Paths.pbfCache)
    }
}
