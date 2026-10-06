import Foundation

extension DataPack {
    /// What the server holds, when it is not what is on disk.
    struct News: Equatable {
        let size: Int64
        let lastModified: String?
        let published: Date?

        /// For the log and the stage line: the date if the server gave one, the size if
        /// it did not.
        var describedShortly: String {
            published.map { "\(Fmt.day($0)) · \(Fmt.bytes(size))" } ?? Fmt.bytes(size)
        }
    }
}
