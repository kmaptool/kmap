import Foundation

/// A cartography choice: the rule set that turns OSM tags into Garmin types, plus the
/// TYP file that decides how those types are drawn.
struct MapStyle: Equatable {
    enum Origin: Equatable {
        case builtin
        case importedTYP(URL)  // a library file, paired with kmap's rule set
        case customDirectory(URL)

        /// What the origin is called where a name is wanted rather than the file it came
        /// from: a reader that is not a person, or a line of prose.
        var name: String {
            switch self {
            case .builtin: return "builtin"
            case .importedTYP: return "library"
            case .customDirectory: return "directory"
            }
        }
    }

    let id: String
    let name: String
    let summary: String
    let origin: Origin
    /// nil means "use mkgmap's own built-in default rules".
    let styleDirectory: URL?
    let typURL: URL?
    let familyID: Int
    let productID: Int

    var hasTYP: Bool { typURL != nil }

    static func == (a: MapStyle, b: MapStyle) -> Bool { a.id == b.id }
}
