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

    /// Opens a file for streaming writes, creating it if it is not there: positioned at
    /// the end when `appending`, and emptied otherwise, so nothing of an older file stays
    /// behind what is written. The one write that cannot be atomic: a download part, a
    /// join of parts, a log. On Windows a file a scanner holds is tried again.
    static func openForWriting(_ url: URL, appending: Bool = true) throws -> FileHandle {
        func open() throws -> FileHandle {
            if !FileManager.default.fileExists(atPath: url.path) {
                guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
                    throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: url.path])
                }
            }
            let handle = try FileHandle(forWritingTo: url)
            if appending { try handle.seekToEnd() } else { try handle.truncate(atOffset: 0) }
            return handle
        }
        #if os(Windows)
        return try FileRetry.attempt(isTransient: Win32File.foundationErrorIsTransient, open)
        #else
        return try open()
        #endif
    }

    /// Copies a file or a directory. Fails where the destination already exists.
    static func copy(_ source: URL, to destination: URL) throws {
        #if os(Windows)
        try Win32File.copy(source, to: destination)
        #else
        try FileManager.default.copyItem(at: source, to: destination)
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
