import Foundation

// A sink's type is named inside the lanes that decode in parallel. Newer compilers want
// the promise that naming it there is safe, which every plain type keeps; older ones have
// no such protocol to name.
#if compiler(>=6.2)
typealias LaneSafeMetatype = SendableMetatype
#else
typealias LaneSafeMetatype = Any
#endif

protocol OSMSink: LaneSafeMetatype {
    /// The parts this sink wants. All of them unless it says otherwise.
    var wantedParts: OSMParts { get }

    /// `tags` alternates key and value indices into the block's string table.
    mutating func node(
        id: Int64,
        lat: Double,
        lon: Double,
        tags: ArraySlice<Int32>,
        block: OSMBlock
    )
    /// Ways keep their keys and values in two parallel runs instead.
    mutating func way(
        id: Int64,
        refs: ArraySlice<Int64>,
        keys: ArraySlice<Int32>,
        values: ArraySlice<Int32>,
        block: OSMBlock
    )
    /// Members arrive as parallel runs of kind (0 node, 1 way, 2 relation), id and role;
    /// the role is a string-table index, as tags are.
    mutating func relation(
        id: Int64,
        memberKinds: ArraySlice<Int32>,
        memberIDs: ArraySlice<Int64>,
        memberRoles: ArraySlice<Int32>,
        keys: ArraySlice<Int32>,
        values: ArraySlice<Int32>,
        block: OSMBlock
    )
    /// Reports a group of this kind in the block, whether or not it was asked for.
    mutating func sawGroup(_ part: OSMParts)
    /// The block's string table is ready and its groups are about to be read.
    mutating func begin(_ block: OSMBlock)
    /// Every group of the block has been read, on the thread that read them.
    mutating func end(_ block: OSMBlock)
}

extension OSMSink {
    var wantedParts: OSMParts { .all }
    mutating func sawGroup(_ part: OSMParts) {}
    mutating func begin(_ block: OSMBlock) {}
    mutating func end(_ block: OSMBlock) {}

    mutating func node(
        id: Int64,
        lat: Double,
        lon: Double,
        tags: ArraySlice<Int32>,
        block: OSMBlock
    ) {}
    mutating func way(
        id: Int64,
        refs: ArraySlice<Int64>,
        keys: ArraySlice<Int32>,
        values: ArraySlice<Int32>,
        block: OSMBlock
    ) {}
    mutating func relation(
        id: Int64,
        memberKinds: ArraySlice<Int32>,
        memberIDs: ArraySlice<Int64>,
        memberRoles: ArraySlice<Int32>,
        keys: ArraySlice<Int32>,
        values: ArraySlice<Int32>,
        block: OSMBlock
    ) {}
}
