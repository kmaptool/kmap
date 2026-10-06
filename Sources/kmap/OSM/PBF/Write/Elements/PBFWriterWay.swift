import Foundation

extension PBFWriter {
    struct Way {
        var id: Int64
        var refs: [Int64]
        var tags: [(String, String)]
    }
}
