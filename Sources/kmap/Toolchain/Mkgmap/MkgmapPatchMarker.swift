import Foundation

#if canImport(FoundationNetworking)
// URLSession lives in a separate module outside Apple's platforms.
import FoundationNetworking
#endif

/// The patched mkgmap jar, and the marker inside it that says which patch it carries.
extension Toolchain {
    /// Where a patched jar is written, and the marker that says a jar carries the patch.
    static let patchedMkgmapName = "mkgmap-patched.jar"
    static let patchMarker = "kmap-patch.properties"
    /// Raise when the edits change. A jar carrying a lower number counts as unpatched and
    /// is rebuilt at the next start or build, see `renewStalePatch`.
    static let patchVersion = 22

    static var patchedMkgmapURL: URL {
        Paths.tools.appendingPathComponent("mkgmap/\(patchedMkgmapName)")
    }

    /// True when this jar carries a patch marker of at least `patchVersion`. Detected by the
    /// marker inside the jar, not by filename, so a copy or a rename still answers correctly.
    static func isPatched(_ jar: URL) -> Bool {
        patchVersion(of: jar) >= patchVersion
    }

    /// 0 for an unpatched jar, 1 for one from before the marker carried a number.
    static func patchVersion(of jar: URL) -> Int { patchState(of: jar).version }

    /// The marker's patch version, as `patchVersion(of:)` gives it, and the Java release the
    /// patched classes were compiled for, nil where the marker does not say.
    static func patchState(of jar: URL) -> (version: Int, release: Int?) {
        guard FileTools.exists(jar), let archive = Archive.current else { return (0, nil) }
        let list = archive.listing(of: jar)
        guard let listing = ProcessProbe.capture(list.executable, list.arguments),
            listing.contains(patchMarker)
        else { return (0, nil) }
        let read = archive.read(patchMarker, from: jar)
        guard let body = ProcessProbe.capture(read.executable, read.arguments) else { return (1, nil) }
        func value(_ key: String) -> Int? {
            body.split(whereSeparator: \.isNewline).first { $0.hasPrefix(key) }
                .flatMap { Int($0.dropFirst(key.count).trimmingCharacters(in: .whitespaces)) }
        }
        return (value("patch-version:") ?? 1, value("class-release:"))
    }
}
