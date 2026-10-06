import Foundation

extension ElementDumper {
    enum Kind: Character {
        case point = "P", line = "L", area = "A"

        /// Its place in a key, and the byte written for it in a dump.
        var slot: Int {
            switch self {
            case .point: return 0
            case .line: return 1
            case .area: return 2
            }
        }

        /// The same kind as the style side names it.
        var styleKind: MapElementKind {
            switch self {
            case .point: return .point
            case .line: return .line
            case .area: return .polygon
            }
        }

        /// From the byte written for it in a dump.
        init?(byte: UInt8) {
            switch byte {
            case 0: self = .point
            case 1: self = .line
            case 2: self = .area
            default: return nil
            }
        }
    }
}
