import Foundation

extension StyleRecovery {
    enum Trouble: Error, CustomStringConvertible, LocalizedError {
        case noTiles
        case noSuchMap(URL)
        case unreadableExtract(URL, PBFError)
        case noExtracts(BBox)
        case noSuchExtract(URL)
        case extractMissesMap(URL, BBox)
        case tooLittleGround(share: Double)

        var isNoExtracts: Bool {
            if case .noExtracts = self { return true }
            return false
        }

        var isTooLittleGround: Bool {
            if case .tooLittleGround = self { return true }
            return false
        }

        var description: String {
            switch self {
            case .extractMissesMap(let url, let frame):
                return "\(url.lastPathComponent) does not reach the map, which lies in \(frame.display)"
                    + " — pass the extract of the region the map shows"
            case .tooLittleGround(let share):
                return "the extracts hold \(Int((share * 100).rounded()))% of the map's data:"
                    + " too little to tell its style"
                    + " — pass the extract of the region the map shows"
            case .noTiles:
                return "no map tiles found — is this a Garmin .img?"
            case .unreadableExtract(let url, let error):
                return "\(url.lastPathComponent): \(error)"
            case .noSuchMap(let url):
                return "no such map: \(Paths.display(url))"
            case .noSuchExtract(let url):
                return "no such extract: \(Paths.display(url))"
            case .noExtracts(let frame):
                return "no cached extract covers \(frame.display) — download the region"
                    + " first, or pass --extract"
            }
        }
    }
}
