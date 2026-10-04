import Foundation

/// Which of the three drawing tables a type code belongs to. The same number means different
/// things in each, and nothing in a bare code records its table, so the kind travels with it.
enum MapElementKind: String, CaseIterable, Equatable {
    case point, line, polygon

    /// The rule file that emits this kind, as mkgmap names it.
    var ruleFile: String {
        switch self {
        case .point: return "points"
        case .line: return "lines"
        case .polygon: return "polygons"
        }
    }

    /// The localized plural name. Not `rawValue + "s"`: the raw value is a format token.
    var plural: String {
        switch self {
        case .point: return t("points")
        case .line: return t("lines")
        case .polygon: return t("polygons")
        }
    }

    /// The section header the TYP compiler uses for this kind.
    var typSection: String {
        switch self {
        case .point: return "[_point]"
        case .line: return "[_line]"
        case .polygon: return "[_polygon]"
        }
    }
}
