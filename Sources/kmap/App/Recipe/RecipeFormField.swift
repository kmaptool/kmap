import Foundation

extension RecipeForm {
    enum Field: Int, CaseIterable {
        case profile
        case style, contours, interval, dem, fixSummits, demSource, zoomPlan, language, codePage,
            familyID
        case routable, healRoads, index, houseNumbers, sea, descriptions
        case customPOIs, hide
        case format, splitMode, parts, output
        case theme, overlap, landOverlap
        case build, save

        var label: String {
            switch self {
            case .profile: return t("Profile")
            case .style: return t("Style")
            case .contours: return t("Contour lines")
            case .interval: return t("Interval")
            case .dem: return t("DEM layer")
            case .fixSummits: return t("Fix summits")
            case .demSource: return t("Elevation data")
            case .zoomPlan: return t("Zoom plan")
            case .language: return t("Labels")
            case .codePage: return t("Code page")
            case .familyID: return t("Family id")
            case .routable: return t("Routable")
            case .healRoads: return t("Repair road ends")
            case .index: return t("Search index")
            case .houseNumbers: return t("House numbers")
            case .sea: return t("Coastlines")
            case .descriptions: return t("Descriptions")
            case .customPOIs: return t("Custom POI file")
            case .hide: return t("Hide on map")
            case .format: return t("Format")
            case .splitMode: return t("Output files")
            case .parts: return t("How many")
            case .output: return t("Folder")
            case .theme: return t("Theme")
            case .overlap: return t("Tile overlap")
            case .landOverlap: return t("Land overlap")
            case .build, .save: return ""
            }
        }
    }
}
