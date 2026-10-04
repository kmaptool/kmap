import Foundation

extension BuildPipeline {
    enum StageID: String, CaseIterable {
        case preflight, dataUpdate, download, elevation, elevationBuild, split,
            compile, collect

        /// Whether this stage runs concurrently with the others rather than before them.
        /// The elevation stages start once the extracts are down and run beside the split.
        var runsBeside: Bool {
            switch self {
            case .elevation, .elevationBuild: return true
            default: return false
            }
        }

        var title: String {
            switch self {
            case .preflight: return t("Check tools and disk")
            case .dataUpdate: return t("Update tools")
            case .download: return t("Download OSM extract")
            case .elevation: return t("Download elevation")
            case .elevationBuild: return t("Contours and DEM")
            case .split: return t("Split into tiles")
            case .compile: return t("Compile map")
            case .collect: return t("Write output")
            }
        }
    }
}
