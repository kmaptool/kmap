import Foundation

extension PBFWriter {
    /// One node. Version and timestamp are not carried; mkgmap reads neither.
    struct Node {
        var id: Int64
        var lat: Double
        var lon: Double
        var tags: [(String, String)]
    }
}
