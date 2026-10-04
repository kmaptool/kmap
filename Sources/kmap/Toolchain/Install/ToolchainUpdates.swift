import Foundation

/// How often a build asks the mirrors whether the data packs have moved on. The
/// boundaries are 2.5 GB, so this is a question about bandwidth as much as freshness.
enum ToolchainUpdates: String, Codable, CaseIterable {
    case everyBuild, weekly, monthly, halfYear, year, never

    var title: String {
        switch self {
        case .everyBuild: return t("every build")
        case .weekly: return t("once a week")
        case .monthly: return t("once a month")
        case .halfYear: return t("every six months")
        case .year: return t("once a year")
        case .never: return t("never")
        }
    }

    /// How long an answer stays good. Nil where no question is asked.
    var interval: TimeInterval? {
        let day = TimeInterval.day
        switch self {
        case .everyBuild: return 0
        case .weekly: return 7 * day
        case .monthly: return 30 * day
        case .halfYear: return 182 * day
        case .year: return 365 * day
        case .never: return nil
        }
    }

    /// Whether a check made then still counts now.
    func stillGood(checked: Date?, now: Date = Date()) -> Bool {
        guard let interval else { return true }
        guard let checked else { return false }
        return now.timeIntervalSince(checked) < interval
    }
}
