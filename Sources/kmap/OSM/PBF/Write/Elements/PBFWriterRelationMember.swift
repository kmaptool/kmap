import Foundation

extension PBFWriter.Relation {
    /// Member kinds follow the PBF enum: 0 node, 1 way, 2 relation.
    struct Member {
        var kind: Int32
        var ref: Int64
        var role: String
    }
}
