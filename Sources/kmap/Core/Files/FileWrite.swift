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

    /// Writes atomically a file only its owner may read, such as one holding passwords.
    /// On the Unixes the file is created with mode 0600, so it is never readable by others,
    /// not even before the rename; on Windows the profile's own permissions keep it.
    static func writePrivate(_ text: String, to url: URL) throws {
        #if os(Windows)
        try write(text, to: url)
        #else
        let temporary = url.deletingLastPathComponent()
            .appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString.prefix(8))")
        let descriptor = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL, 0o600)
        guard descriptor >= 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        do {
            let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
            try handle.write(contentsOf: Data(text.utf8))
            try handle.close()
            guard posixRename(temporary.path, url.path) == 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
        } catch {
            unlink(temporary.path)
            throw error
        }
        #endif
    }

    /// Moves a file or a directory. Fails where the destination already exists.
    static func move(_ source: URL, to destination: URL) throws {
        #if os(Windows)
        try Win32File.move(source, to: destination)
        #else
        try FileManager.default.moveItem(at: source, to: destination)
        #endif
    }

    /// Renames within one volume, never copying: fails where `destination` is on another
    /// volume or already there, a dangling link included.
    static func rename(_ source: URL, to destination: URL) throws {
        #if os(Windows)
        try Win32File.rename(source, to: destination)
        #elseif canImport(Darwin)
        guard renamex_np(source.path, destination.path, UInt32(RENAME_EXCL)) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        #else
        // glibc's renameat2 is not in Swift's headers: checked first, a race left open.
        var held = stat()
        guard lstat(destination.path, &held) != 0 else { throw POSIXError(.EEXIST) }
        guard posixRename(source.path, destination.path) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        #endif
    }

    /// Whether 2 existing paths are on one volume; false where either cannot be asked.
    static func sameVolume(_ a: URL, _ b: URL) -> Bool {
        #if os(Windows)
        guard let one = Win32File.volume(of: a.nativePath), let other = Win32File.volume(of: b.nativePath)
        else { return false }
        return one == other
        #else
        var one = stat()
        var other = stat()
        guard stat(a.path, &one) == 0, stat(b.path, &other) == 0 else { return false }
        return one.st_dev == other.st_dev
        #endif
    }

    /// Puts `fresh` in the place of `destination`, the earlier one set aside until the new
    /// one is in and put back if it is not.
    static func replace(_ destination: URL, with fresh: URL, aside: (URL) -> URL = setAside) throws {
        try replace([(destination, fresh)], aside: aside)
    }

    /// Puts each fresh one in its destination's place, all or none: the earlier ones are
    /// set aside until every new one is in, and all put back if one is not.
    static func replace(_ pairs: [(destination: URL, fresh: URL)], aside: (URL) -> URL = setAside) throws {
        #if !os(Windows)
        // 1 file for 1 file is 1 atomic rename on the Unixes, with nothing set aside.
        if pairs.count == 1, let pair = pairs.first, !isDirectoryItself(pair.destination),
            !isDirectoryItself(pair.fresh), posixRename(pair.fresh.path, pair.destination.path) == 0
        {
            return
        }
        #endif
        var asides: [(destination: URL, aside: URL)] = []
        var landed: [(destination: URL, fresh: URL)] = []
        do {
            for pair in pairs where exists(pair.destination) {
                let kept = aside(pair.destination)
                removeIfPresent(kept)
                try move(pair.destination, to: kept)
                asides.append((pair.destination, kept))
            }
            for pair in pairs {
                try move(pair.fresh, to: pair.destination)
                landed.append(pair)
            }
        } catch {
            for pair in landed.reversed() { try? move(pair.destination, to: pair.fresh) }
            for pair in asides.reversed() { try? move(pair.aside, to: pair.destination) }
            throw error
        }
        for pair in asides { removeIfPresent(pair.aside) }
    }

    /// Where `replace` keeps the earlier one meanwhile.
    static func setAside(_ url: URL) -> URL {
        url.deletingLastPathComponent().appendingPathComponent(url.lastPathComponent + ".old")
    }

    /// Settles what a killed `replace` left in a folder: an earlier one with nothing in
    /// its place goes back, and one whose successor arrived goes.
    static func settleSetAside(in folder: URL) {
        let entries = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        for name in entries where name.hasSuffix(".old") {
            let aside = folder.appendingPathComponent(name)
            let original = folder.appendingPathComponent(String(name.dropLast(".old".count)))
            if exists(original) { removeIfPresent(aside) } else { try? move(aside, to: original) }
        }
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

#if !os(Windows)
/// The C call, out of reach inside `FileTools`, whose own `rename` shadows it.
private func posixRename(_ from: String, _ to: String) -> Int32 {
    rename(from, to)
}
#endif
