import Foundation

extension URL {
    /// Whether two URLs name the same file, resolving symlinks first. `==` alone treats
    /// two spellings of one path as different.
    func sameFile(as other: URL) -> Bool {
        resolvingSymlinksInPath().standardizedFileURL
            == other.resolvingSymlinksInPath().standardizedFileURL
    }
}
