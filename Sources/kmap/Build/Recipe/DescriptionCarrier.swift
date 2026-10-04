import Foundation

extension BuildRecipe {
    /// Where OSM `description` is carried so the device can show it. Every carrier but
    /// `inName` uses an address field, which requires the object to be a POI with an
    /// address block and is shown only when the object is opened, never on the map.
    enum DescriptionCarrier: String, CaseIterable {
        /// Descriptions are not carried.
        case off
        /// Rides in the address line; the text can reach the address index.
        case street
        /// Stays out of mkgmap's index, which covers POI names and not phone numbers. The
        /// receiver labels the line as a phone number, and some firmware hides it.
        case phone
        /// Rides in the region line. Renders reliably; region-based address search stops
        /// working.
        case region
        /// Rides in the postcode line.
        case postcode
        /// Appended to the object's name in brackets. Works on anything that carries a
        /// name, and is the only carrier also drawn on the map.
        case inName

        var label: String {
            switch self {
            case .off: return t("off")
            case .street: return t("as address line")
            case .phone: return t("as phone line (kept out of search)")
            case .region: return t("as region line (what OpenTopoMap uses)")
            case .postcode: return t("as postcode line")
            case .inName: return t("after the name in brackets — also drawn on the map")
            }
        }

        /// The address tag the text rides in; nil for carriers that use none.
        var tag: String? {
            switch self {
            case .off, .inName: return nil
            case .street: return "mkgmap:street"
            case .phone: return "mkgmap:phone"
            case .region: return "mkgmap:region"
            case .postcode: return "mkgmap:postal_code"
            }
        }
    }
}
