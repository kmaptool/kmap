import Foundation

extension RegionSuggestion {
    /// Every downloadable leaf the map draws on, the biggest share of its data first: the
    /// ground recover reads more of, 1 region at a time. Unlike the offer, a leaf the map
    /// covers only in part counts too.
    static func drawnOnLeaves(on drawn: DrawnGround, index: RegionIndex) -> [Candidate] {
        index.regions.values
            .filter { $0.pbfURL != nil && !$0.hasChildren }
            .filter { region in
                region.bbox.intersects(drawn.frame) || region.boxes.contains { $0.intersects(drawn.frame) }
            }
            .map { stance(of: $0, on: drawn) }
            .filter(\.isDrawnOn)
            .sorted { ($0.share, $1.region.id) > ($1.share, $0.region.id) }
    }
}
