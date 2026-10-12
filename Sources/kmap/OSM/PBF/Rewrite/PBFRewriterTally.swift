import Foundation

extension PBFRewriter {
    /// Blocks copied, blocks rebuilt, and objects added.
    struct Tally {
        var copied = 0
        var rebuilt = 0
        var addedNodes = 0
        var addedWays = 0
        var tagged = 0
        var ferrataEnds = 0
        var dropped = 0
        var marked = 0
        var contourBlocks = 0
        var renamed = 0
    }
}
