import Foundation

extension BuildPipeline {
    /// One compiled tile, with what it weighs.
    struct Weighed {
        let tile: Tile
        let url: URL
        let size: Int64
    }
}
