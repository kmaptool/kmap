import Foundation

/// What a finished map is written as: `.img` files for a device's card, a `.gmap` folder
/// BaseCamp reads from the computer with no device attached, or both.
enum OutputFormat: String, CaseIterable, Equatable {
    case img, gmap, both

    var writesCardFiles: Bool { self != .gmap }
    var writesGmap: Bool { self != .img }

    var label: String {
        switch self {
        case .img: return t("img — for the device")
        case .gmap: return t("gmap — for BaseCamp")
        case .both: return t("img and gmap")
        }
    }

    var note: String {
        switch self {
        case .img: return t("copied to the Garmin folder on the device or its card")
        case .gmap: return t("installed on the computer; BaseCamp needs no device")
        case .both: return t("one for the device, one for the computer")
        }
    }
}
