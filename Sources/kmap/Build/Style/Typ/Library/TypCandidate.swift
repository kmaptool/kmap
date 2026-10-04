import Foundation

/// Getting a TYP into the library: finding candidates on the mounted volumes,
/// taking a copy in, the import log, and the kept originals a style can be
/// restored from.
struct TypCandidate: Equatable, Identifiable, Sendable {
    /// The file it would come from.
    let url: URL
    /// True when the TYP is inside a Garmin `.img` and has to be lifted out.
    let isEmbedded: Bool

    let familyID: Int
    let productID: Int
    let size: Int64

    /// What to call it on screen: the file's own name, or the map's for an embedded one.
    let name: String
    /// The folder it was found in, for telling two copies of the same product apart.
    let location: String

    /// The TYP's own bytes, boiled down to a number. Zero where it could not be read.
    ///
    /// A family id names the product, not the file: one product may ship several TYPs
    /// under one family, and several versions of a map may ship different ones.
    var fingerprint: UInt64 = 0

    var id: String { "\(url.path)#\(familyID)" }
}
