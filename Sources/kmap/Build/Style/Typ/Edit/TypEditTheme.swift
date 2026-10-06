import Foundation

extension TypEdit {
    /// Which of a TYP's 2 drawings a build keeps.
    ///
    /// Night is extra colours in the same element, not a separate section: a solid pair is
    /// day then night, 4 are day fill, day casing, night fill, night casing (or ink and
    /// background for a pattern), plus a second picture on a point and `NightCustomColor`.
    enum Theme: String, CaseIterable {
        /// The file as its author wrote it.
        case all
        /// Only what the file says about day; the night slots go.
        case day
        /// The night drawing moved into the day slots, so it shows at any hour.
        case night
    }
}
