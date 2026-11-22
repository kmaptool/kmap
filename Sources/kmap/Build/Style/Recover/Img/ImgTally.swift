import Foundation

extension ImgElements {
    /// What 1 subdivision draws off the ground a run read: its rectangle, and how many
    /// elements of each code, keyed as `Evidence.slot` keys them.
    struct Tally: Sendable {
        let box: BBox
        var codes: [Int: Int]
    }
}
