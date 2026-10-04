import Foundation

/// What a fetch or a download can fail with.
enum DownloadError: Error, LocalizedError {
    case badStatus(Int)
    case rangesIgnored
    case noContentLength
    case checksumMismatch(expected: String, got: String)
    case cancelled
    case io(String)

    var errorDescription: String? {
        switch self {
        case .badStatus(let code): return t("server returned HTTP %d", code)
        case .rangesIgnored: return t("server ignored the range request")
        case .noContentLength: return t("server did not report a file size")
        case .checksumMismatch(let e, let g):
            return t("MD5 mismatch — expected %1$@, got %2$@", e, g)
        case .cancelled: return t("cancelled")
        case .io(let m): return m
        }
    }
}
