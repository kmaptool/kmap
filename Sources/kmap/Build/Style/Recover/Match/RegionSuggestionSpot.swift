import Foundation

extension RegionSuggestion.DrawnGround {
    /// A rectangle of the map with the bytes of RGN it holds.
    struct Spot {
        let box: BBox
        let weight: Double
    }
}
