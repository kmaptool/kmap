import Foundation

/// The version this build reports.
///
/// The number itself lives in the VERSION file at the repository root — one place to
/// edit, no code. `make version` (run before every make build) regenerates
/// `VersionNumber.swift` from it; that file is committed, so plain `swift build`
/// still needs nothing but the sources. Raised whenever build output changes observably.
enum Version {
    /// The line `kmap --version` prints.
    static var line: String { "kmap \(number)" }

    /// `line`, with the build configuration appended for a debug build, which runs
    /// several times slower.
    static var full: String {
        #if DEBUG
        return "\(line) (debug)"
        #else
        return line
        #endif
    }
}
