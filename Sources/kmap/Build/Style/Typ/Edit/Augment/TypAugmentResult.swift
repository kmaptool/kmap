import Foundation

extension TypAugment {
    /// The TYP a build compiles, and what was done to it.
    struct Result {
        /// The TYP the build should compile. The original where nothing had to be added.
        let url: URL
        /// Which types were added, for the log.
        let added: [String]
        /// What was said about the day/night pass, where it ran.
        var theme: String?
        /// Why nothing could be added, where that is the case.
        let refusal: String?
        /// Marks that had to move because the borrowed style already draws their
        /// number: old code to new, per kind. The rules emitting them move too.
        var moved: [MapElementKind: [Int: Int]] = [:]
        /// Whether the draw order was rearranged to put the woods over the ground tints.
        var woodsLaidOver = false
        /// The mkgmap option that goes with the copies laid over the woods, where there
        /// are any: `--x-shape-lift=`, each fill with its copy, then the woods.
        var shapeLift: String?
    }
}
