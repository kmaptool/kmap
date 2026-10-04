import Foundation

/// Which of a block's three kinds of object a sink wants. Groups not asked for are
/// skipped rather than unpacked; the block is inflated either way.
struct OSMParts: OptionSet {
    let rawValue: UInt8
    static let nodes = OSMParts(rawValue: 1)
    static let ways = OSMParts(rawValue: 2)
    static let relations = OSMParts(rawValue: 4)
    static let all: OSMParts = [.nodes, .ways, .relations]
}
