import Foundation

/// Errors raised while reading an OSM PBF.
enum PBFError: Error, CustomStringConvertible, LocalizedError {
    case truncated(String)
    case unsupportedCompression(String)
    case unsupportedFeature(String)

    var description: String {
        switch self {
        case .truncated(let what): return "the file ends in the middle of \(what)"
        case .unsupportedCompression(let how): return "blob compressed with \(how), which this reader does not do"
        case .unsupportedFeature(let feature):
            return "the file needs a reader that knows \(feature), which kmap does not"
                + " (a history file, or ways that carry their own locations)"
        }
    }
}
