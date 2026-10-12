import Foundation

extension BarrierScan {
    /// What a barrier stands on. Ordered by which wins where a node belongs to several
    /// ways: `fence` sits just above `none`, so any road or path the gate also stands on
    /// takes precedence.
    enum Kind: Int, Comparable {
        case none = 0, fence, major, minor, path

        var word: String {
            switch self {
            case .none: return "none"
            case .fence: return "fence"
            case .major: return "major"
            case .minor: return "minor"
            case .path: return "path"
            }
        }

        static func < (a: Kind, b: Kind) -> Bool { a.rawValue < b.rawValue }
    }
}
