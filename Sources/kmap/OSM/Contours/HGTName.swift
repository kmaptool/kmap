import Foundation

/// The naming convention every elevation tile follows: its south-west corner in whole
/// degrees, hemisphere first -- N44E033, S34W071.
///
/// Written out in five places before this, and one of them assumed the northern and
/// eastern hemispheres in both directions: the peaks pass built "N%02dE%03d" whatever the
/// coordinates were, so no summit anywhere south or west of Greenwich ever found its tile,
/// and another read the corner back out of the name without its sign. Both are silent --
/// the build finishes and the peaks are simply not there.
enum HGTName {
    /// The name of the tile holding a point, without the extension.
    static func of(lat: Int, lon: Int) -> String {
        String(format: "%@%02d%@%03d",
               lat < 0 ? "S" : "N", abs(lat),
               lon < 0 ? "W" : "E", abs(lon))
    }

    /// The tile holding a coordinate: whole degrees, rounded down, as the corner is.
    static func of(lat: Double, lon: Double) -> String {
        of(lat: Int(lat.rounded(.down)), lon: Int(lon.rounded(.down)))
    }

    /// The corner a name stands for, or nil if it is not one of these names.
    static func corner(of name: String) -> (lat: Int, lon: Int)? {
        let stem = name.hasSuffix(".hgt") ? String(name.dropLast(4)) : name
        let letters = Array(stem.uppercased())
        guard letters.count >= 7 else { return nil }
        guard letters[0] == "N" || letters[0] == "S" else { return nil }
        guard letters[3] == "E" || letters[3] == "W" else { return nil }
        guard let degreesNorth = Int(String(letters[1...2])),
              let degreesEast = Int(String(letters[4...6])) else { return nil }
        return (lat: letters[0] == "S" ? -degreesNorth : degreesNorth,
                lon: letters[3] == "W" ? -degreesEast : degreesEast)
    }
}
