import XCTest
@testable import kmap

/// The region suggestion against real maps and the cached Geofabrik index.
///
/// The synthetic tests hold the rules; this holds the world. Each entry is a map that
/// once produced a wrong suggestion — a neighbour the map merely touches, or a region
/// on the far side of the antimeridian. Maps and expectations are the developer's own
/// and live outside the repository; see `LocalTestMaps`. The class skips where they
/// are absent.
final class RealMapSuggestionTests: XCTestCase {

    private static var index: RegionIndex?

    /// The index the application fetched. A test run gives `Paths` a sandbox of its
    /// own, so the real cache is named outright; reading it changes nothing.
    private func loadedIndex() throws -> RegionIndex {
        if let held = Self.index { return held }
        let cached = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".kmap/cache/geofabrik-index.json")
        try XCTSkipUnless(FileTools.exists(cached), "no cached Geofabrik index")
        let fresh = RegionIndex()
        try fresh.parse(try Data(contentsOf: cached))
        Self.index = fresh
        return fresh
    }

    func testEveryMapIsOfferedTheGroundItIsMadeOf() throws {
        let expectations = LocalTestMaps.load()?.suggestion ?? []
        try XCTSkipUnless(!expectations.isEmpty, "no local map expectations")
        let index = try loadedIndex()
        var seen = 0
        for expectation in expectations {
            let url = URL(fileURLWithPath: expectation.path)
            guard FileTools.exists(url) else { continue }
            seen += 1

            let drawn = RegionSuggestion.drawnGround(of: url)
            let offered = RegionSuggestion.suggestedRegions(on: drawn, index: index)
            let listed = offered.map {
                String(format: "%@ (share %.0f%%, inside %.0f%%)",
                       $0.region.id, $0.share * 100, $0.inside * 100)
            }.joined(separator: ", ")

            XCTAssertFalse(offered.isEmpty, "\(url.lastPathComponent): nothing offered")
            if !expectation.first.isEmpty {
                XCTAssertEqual(offered.first?.region.id, expectation.first,
                               "\(url.lastPathComponent): \(listed)")
            }
            for banned in expectation.never {
                XCTAssertFalse(offered.contains { $0.region.id == banned },
                               "\(url.lastPathComponent) offered \(banned): \(listed)")
            }
        }
        try XCTSkipUnless(seen > 0, "none of the listed maps is on this machine")
    }
}
