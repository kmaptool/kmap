import Foundation

/// The catalogue kmap offers, written from the style at the moment it is complete and
/// before any build choice has been applied, which is the file a hide is substituted
/// into. Every build refreshes it; the copy in the binary is the fallback for a first run
/// with nothing materialized yet.
enum HideableCatalogue {
    /// Kept beside the rules it was read from, so the two are made and discarded together.
    static var url: URL {
        StyleCatalog.baseStyleDirectory.appendingPathComponent("hideable.txt")
    }

    private static let lock = NSLock()
    private static var held: String?

    /// Where the catalogue for a points file goes: beside it, not at `url`. The base style
    /// is built in a staging directory and swapped into place, which would remove a file
    /// written to the shared path.
    static func destination(besidePoints points: URL) -> URL {
        points.deletingLastPathComponent().appendingPathComponent("hideable.txt")
    }

    /// Writes the catalogue for this style and drops the cached text, returning the number
    /// of features. Best-effort: a failed write leaves the previous catalogue in place.
    @discardableResult
    static func record(pointsAt points: URL) -> Int {
        guard let text = try? String(contentsOf: points, encoding: .utf8) else { return 0 }
        let made = HideableGenerator.catalogue(fromPoints: text)
        let beside = destination(besidePoints: points)
        guard (try? made.text.write(to: beside, atomically: true, encoding: .utf8)) != nil else {
            return 0
        }
        lock.lock(); held = made.text; lock.unlock()
        HideableFeature.forget()
        return made.features
    }

    /// The catalogue text: what the last style produced, or what the binary carries.
    static func text() -> String {
        lock.lock()
        if let held { lock.unlock(); return held }
        lock.unlock()
        let found = (try? String(contentsOf: url, encoding: .utf8))
            ?? StyleAssets.hideableCatalogue
        lock.lock(); held = found; lock.unlock()
        return found
    }

    /// Drops the cached catalogue text.
    static func forget() {
        lock.lock(); held = nil; lock.unlock()
    }
}
