import Foundation

extension PBFRewriter {
    enum Trouble: Error, CustomStringConvertible, LocalizedError {
        case mixedBlock
        case writesOverItsInput(String)

        var description: String {
            switch self {
            case .mixedBlock:
                "a block holds relations as well as nodes or ways, which this writer"
                    + " does not rebuild -- report the extract, it is not the usual layout"
            case .writesOverItsInput(let path):
                "\(path) is read while it is written: name another file for the output"
            }
        }

        /// Throws where `destination` is `source` or one of `others`, by any spelling: the
        /// output takes the input's place when it is done, and a file still being read
        /// will not move on Windows.
        static func refuseOverwriting(_ source: URL, _ others: [URL] = [], with destination: URL) throws {
            if ([source] + others).contains(where: destination.sameFile) {
                throw Trouble.writesOverItsInput(destination.nativePath)
            }
        }
    }
}
