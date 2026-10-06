import Foundation

extension PBFWriter {
    struct Relation {
        var id: Int64
        var members: [Member]
        var tags: [(String, String)]
    }
}
