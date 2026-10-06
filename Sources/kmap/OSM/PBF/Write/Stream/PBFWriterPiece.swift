import Foundation

extension PBFWriter {
    /// A batch on its way through the compression pipeline to the file.
    enum Piece: Sendable {
        /// A blob already compressed by its original writer, passed through unchanged.
        case copied(header: [UInt8], blob: [UInt8])
        case toCompress(kind: String, payload: [UInt8])
    }
}
