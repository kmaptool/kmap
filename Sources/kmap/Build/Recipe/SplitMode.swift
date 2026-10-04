import Foundation

/// How a finished map is cut into files. A receiver reads several files from one card and
/// draws them together, so tiles, their ids and the routing graph are the same either way;
/// the split decides only what can be installed or left off separately.
enum SplitMode: Equatable {
    /// A continent-sized extract cut to fit a card needs this many.
    static let mostParts = 64

    /// As few files as the FAT32 file-size limit allows. Tiles are weighed after they are
    /// compiled rather than estimated.
    case fitCard
    /// One file per region in the map, so a region can be left off the card.
    case perRegion
    /// One file per country, gathering that country's regions together.
    case perCountry
    /// Exactly this many files, in equal weights.
    case count(Int)

    /// Stored in settings as a word plus a number, so a new case does not invalidate it.
    var settingsID: String {
        switch self {
        case .fitCard: return "fit"
        case .perRegion: return "region"
        case .perCountry: return "country"
        case .count: return "custom"
        }
    }

    var fileCount: Int {
        if case .count(let n) = self { return max(1, n) }
        return 0
    }

    init(settingsID: String, count: Int) {
        switch settingsID {
        case "region": self = .perRegion
        case "country": self = .perCountry
        case "custom": self = .count(max(1, count))
        default: self = .fitCard
        }
    }

    var label: String {
        switch self {
        case .fitCard: return t("automatic — as few as fit a card")
        case .perRegion: return t("one per region")
        case .perCountry: return t("one per country")
        case .count(let n): return tn("%d file(s)", n)
        }
    }
}
