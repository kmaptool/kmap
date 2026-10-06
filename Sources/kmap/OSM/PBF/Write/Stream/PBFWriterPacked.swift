import Foundation

extension PBFWriter {
    /// A batch's blocks with their deflated bodies, empty where there is none.
    struct Packed: Sendable {
        let pieces: [Piece]
        let bodies: [[UInt8]]
    }
}
