import Foundation

/// Errors raised while reading an OSM PBF.
enum PBFError: Error, CustomStringConvertible, LocalizedError {
    case truncated(String)
    case unsupportedCompression(String)
    case unsupportedFeature(String)
    case plainNodes

    var description: String {
        switch self {
        case .truncated(let what): return "the file ends in the middle of \(what)"
        case .unsupportedCompression(let how): return "blob compressed with \(how), which this reader does not do"
        case .plainNodes:
            return "the file stores its nodes 1 by 1 rather than dense, which kmap does not read;"
                + " osmium cat with -f pbf,pbf_dense_nodes=true rewrites it"
        case .unsupportedFeature(let feature):
            return "the file needs a reader that knows \(feature), which kmap does not"
                + " (a history file, or ways that carry their own locations)"
        }
    }
}
