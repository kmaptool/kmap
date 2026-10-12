import Foundation

extension StylePort {
    /// One porting: their code, and how sure the evidence is.
    struct Ported {
        let ours: Int
        let theirs: Int
        let kind: MapElementKind
        /// The meaning both sides were seen drawing, for the report.
        let meaning: String
        /// How many of their elements were identified as that meaning, and as the other
        /// meanings their map draws with the same picture on this number.
        let witnesses: Int
        /// How wide the line is drawn, where that is not the picture's own width: a
        /// number of ours drawn at every zoom wears the far rung's width and the near
        /// rung's paint, and no road is wider than one above it in the hierarchy.
        var width: Int?
        /// What settles a number two meanings share: the ground covered for a fill,
        /// the sightings for anything else.
        var weight: Double = 0
        /// The other looks that wanted this number and lost: one number of ours for
        /// several things of theirs, which is where a look goes wrong.
        var rivals: [Rival] = []
    }
}
