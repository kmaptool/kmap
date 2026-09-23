import Foundation

/// Writing, moving and removing files, the one way kmap does each.
///
/// On the Unixes these are Foundation's own calls. On Windows they go through the Win32
/// API in `Win32File`: Foundation's atomic write there closes the finished temporary file
/// and opens it again to rename it, and in that gap a scanner can take the file and the
/// rename fails as a permission error. `Win32File` keeps one handle from creation to
/// rename, and tries again the operations another process can still block.
extension FileTools {
    /// Writes atomically: the file is either the old contents or the new, never half.
    static func write(_ data: Data, to url: URL) throws {
        #if os(Windows)
        try Win32File.writeAtomically(data, to: url)
        #else
        try data.write(to: url, options: .atomic)
        #endif
    }

    /// The same for text, as UTF-8.
    static func write(_ text: String, to url: URL) throws {
        try write(Data(text.utf8), to: url)
    }

    /// Moves a file or a directory. Fails where the destination already exists.
    static func move(_ source: URL, to destination: URL) throws {
        #if os(Windows)
        try Win32File.move(source, to: destination)
        #else
        try FileManager.default.moveItem(at: source, to: destination)
        #endif
    }

    /// Removes a file, or a directory and everything in it.
    static func remove(_ url: URL) throws {
        #if os(Windows)
        try Win32File.remove(url)
        #else
        try FileManager.default.removeItem(at: url)
        #endif
    }

    /// Removes what may or may not be there, and says nothing either way.
    static func removeIfPresent(_ url: URL) {
        try? remove(url)
    }

    /// Empties a directory without removing the directory itself.
    static func emptyDirectory(_ url: URL) {
        guard let items = try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)
        else { return }
        for item in items { removeIfPresent(item) }
    }
}
