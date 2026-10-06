import Foundation

/// The rows of the settings screen.
extension SettingsScreen {
    enum Field: Int, CaseIterable {
        case uiLanguage
        case output, work, connections, toolchainUpdates, heap, maxNodes, keepWork
        case usgsUser, usgsPassword, jaxaUser, jaxaPassword
        case mkgmapJar, javaBinary, clearCache, clearElevation

        var label: String {
            switch self {
            case .uiLanguage: return t("Language")
            case .output: return t("Output folder")
            case .work: return t("Work folder")
            case .usgsUser: return t("USGS login")
            case .usgsPassword: return t("USGS password")
            case .jaxaUser: return t("JAXA login")
            case .jaxaPassword: return t("JAXA password")
            case .connections: return t("Download streams")
            case .toolchainUpdates: return t("Data updates")
            case .heap: return t("Java heap")
            case .maxNodes: return t("Nodes per tile")
            case .keepWork: return t("Keep work files")
            case .mkgmapJar: return "mkgmap.jar"
            case .javaBinary: return "java"
            case .clearCache: return t("Cached extracts")
            case .clearElevation: return t("Cached elevation")
            }
        }

        var isLogin: Bool {
            switch self {
            case .usgsUser, .usgsPassword, .jaxaUser, .jaxaPassword: return true
            default: return false
            }
        }

        /// Edited as text rather than chosen from a list.
        var isText: Bool {
            switch self {
            case .output, .work, .mkgmapJar, .javaBinary: return true
            default: return isLogin
            }
        }

        var isPassword: Bool { self == .usgsPassword || self == .jaxaPassword }

        /// The login service behind a login or password row.
        var service: ElevationLogins.Service? {
            switch self {
            case .usgsUser, .usgsPassword: return .srtm
            case .jaxaUser, .jaxaPassword: return .alos
            default: return nil
            }
        }

        /// What a file dialog looks for on this row's behalf.
        var wants: FilePicker.Wanted? {
            switch self {
            case .output, .work: return .directory
            case .mkgmapJar: return .file(extensions: ["jar"])
            case .javaBinary: return .file(extensions: [])
            default: return nil
            }
        }

        var help: String {
            switch self {
            case .uiLanguage: return t("the interface, not the map — labels are a build choice")
            case .output: return t("finished maps, each build in its own dated folder")
            case .work: return t("scratch space during a build; emptied when it finishes")
            case .usgsUser:
                return t("ers.cr.usgs.gov/register — unlocks srtm1, 30 m instead of 90 m")
                    + SettingsScreen.verdictNote(.srtm)
            case .usgsPassword: return t("kept in ~/.pyhgtmap/config.yaml, readable only by you")
            case .jaxaUser:
                return t("eorc.jaxa.jp/ALOS/en/aw3d30 — unlocks alos1, also 30 m")
                    + SettingsScreen.verdictNote(.alos)
            case .jaxaPassword: return t("same file, same permissions")
            case .connections: return t("parallel byte-range connections per download")
            case .toolchainUpdates:
                return t(
                    "how often a build asks whether the coastline and boundary"
                        + " packs have been republished"
                )
            case .heap: return t("memory handed to mkgmap; 0 means auto")
            case .maxNodes: return t("upper limit on one map tile; the default suits most machines")
            case .keepWork: return t("keep intermediate tiles and contours after a build")
            case .mkgmapJar, .javaBinary: return t("leave empty and kmap finds it on its own")
            case .clearCache: return t("downloaded .osm.pbf extracts kept for reuse")
            case .clearElevation: return t("downloaded elevation data; cleared, it is downloaded again")
            }
        }
    }

    /// The last verdict on a login, as a suffix for its help line.
    nonisolated static func verdictNote(_ service: ElevationLogins.Service) -> String {
        let login = ElevationLogins.load(service)
        guard !login.user.isEmpty, !login.password.isEmpty else { return "" }
        switch ElevationLogins.check(service)?.verdict {
        case .valid: return "  ·  " + t("the login works")
        case .rejected: return "  ·  " + t("refused — the source is not offered")
        case .unreachable: return "  ·  " + t("could not be checked")
        case nil: return ""
        }
    }
}
