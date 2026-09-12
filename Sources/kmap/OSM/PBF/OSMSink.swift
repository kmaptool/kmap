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

protocol OSMSink {
    /// The parts this sink wants. All of them unless it says otherwise.
    var wantedParts: OSMParts { get }

    /// `tags` alternates key and value indices into the block's string table.
    mutating func node(id: Int64, lat: Double, lon: Double,
                       tags: ArraySlice<Int32>, block: OSMBlock)
    /// Ways keep their keys and values in two parallel runs instead.
    mutating func way(id: Int64, refs: ArraySlice<Int64>,
                      keys: ArraySlice<Int32>, values: ArraySlice<Int32>, block: OSMBlock)
    /// Members arrive as parallel runs of kind (0 node, 1 way, 2 relation), id and role;
    /// the role is a string-table index, as tags are.
    mutating func relation(id: Int64, memberKinds: ArraySlice<Int32>,
                           memberIDs: ArraySlice<Int64>, memberRoles: ArraySlice<Int32>,
                           keys: ArraySlice<Int32>, values: ArraySlice<Int32>,
                           block: OSMBlock)
    /// Reports a group of this kind in the block, whether or not it was asked for.
    mutating func sawGroup(_ part: OSMParts)
    /// The block's string table is ready and its groups are about to be read.
    mutating func begin(_ block: OSMBlock)
}

extension OSMSink {
    var wantedParts: OSMParts { .all }
    mutating func sawGroup(_ part: OSMParts) {}
    mutating func begin(_ block: OSMBlock) {}

    mutating func node(id: Int64, lat: Double, lon: Double,
                       tags: ArraySlice<Int32>, block: OSMBlock) {}
    mutating func way(id: Int64, refs: ArraySlice<Int64>,
                      keys: ArraySlice<Int32>, values: ArraySlice<Int32>, block: OSMBlock) {}
    mutating func relation(id: Int64, memberKinds: ArraySlice<Int32>,
                           memberIDs: ArraySlice<Int64>, memberRoles: ArraySlice<Int32>,
                           keys: ArraySlice<Int32>, values: ArraySlice<Int32>,
                           block: OSMBlock) {}
}
