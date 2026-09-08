import Foundation

/// What a repair carries on the map.
///
/// Everything goes in the name. The device has its own ideas about when to show the rest
/// of an object's detail, and a walker standing at the gap should not have to coax it out
/// of a card -- so the one field that always shows carries the lot.
enum RepairLabel {
    /// The mark standing halfway along the link: what it crosses, how high that is if OSM
    /// knows, and how far the link reaches. The nouns live in Assets/style-words.txt,
    /// keyed by the OSM value the planner recorded; an unknown value is "an obstacle".
    static func sign(_ what: String, _ metres: Double, _ height: Float, _ language: String) -> String {
        let words = StyleWords(cyrillic: language == "ru")
        let unit = language == "ru" ? "м" : "m"
        let key = "repair." + (what.isEmpty ? "obstacle" : what)
        var name = words(StyleWords.knows(key) ? key : "repair.obstacle")
        if height.isFinite {
            name += String(format: language == "ru" ? " высотой %.1f %@" : " %.1f %@ high",
                           height, unit)
        }
        return String(format: "%@, %.2f %@", name, metres, unit)
    }

    /// The link itself: what it is, and then the sign's own words, so it reads the same
    /// whichever of the two a finger lands on.
    static func link(_ what: String, _ metres: Double, _ height: Float, _ language: String) -> String {
        let inner = sign(what, metres, height, language)
        let lowered = inner.prefix(1).lowercased() + inner.dropFirst()
        return language == "ru"
            ? "Перемычка (достроена, \(lowered))"
            : "Repaired link (\(lowered))"
    }
}
