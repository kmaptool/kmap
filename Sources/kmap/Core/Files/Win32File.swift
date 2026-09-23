#if os(Windows)
import Foundation
import WinSDK

/// Files on Windows through the Win32 API itself, where the error codes are the system's
/// own and a handle can be held from the first byte to the rename.
///
/// Two things Windows does that the Unixes do not: any process may open a file so that
/// nobody else can replace, rename or delete it, and the programs watching the file
/// system do exactly that to a fresh file for a moment. So the temporary file behind an
/// atomic write is opened once, shared with nobody, written and renamed on that one
/// handle; and a rename, a move or a delete that the system refuses because the file is
/// held is tried again through `FileRetry`.
enum Win32File {
    struct Failure: Error, CustomStringConvertible, LocalizedError {
        let operation: String
        let path: String
        let code: DWORD

        var description: String { "\(operation) \(path): Windows error \(code)" }
        var errorDescription: String? { description }
    }

    /// Bytes handed to one `WriteFile`; the call takes a 32-bit count.
    private static let writeChunk = 1 << 30

    // MARK: What passes

    /// The codes that say another process holds the file, which passes: held so that it
    /// may not be shared, held so that it may not be deleted, locked in part, or mapped
    /// into memory.
    static func isTransient(_ code: DWORD) -> Bool {
        code == DWORD(ERROR_SHARING_VIOLATION) || code == DWORD(ERROR_ACCESS_DENIED)
            || code == DWORD(ERROR_LOCK_VIOLATION) || code == DWORD(ERROR_USER_MAPPED_FILE)
    }

    static func isTransient(_ error: Error) -> Bool {
        (error as? Failure).map { isTransient($0.code) } ?? false
    }

    // MARK: Writing

    /// Writes `data` beside `url` into a temporary file nobody else may open, then renames
    /// it over `url` on the same handle. The temporary file is deleted on any failure.
    static func writeAtomically(_ data: Data, to url: URL) throws {
        let path = url.nativePath
        let temporary =
            url.deletingLastPathComponent().nativePath + "\\." + url.lastPathComponent
            + ".\(UUID().uuidString.prefix(8)).tmp"
        let handle = temporary.withCString(encodedAs: UTF16.self) {
            CreateFileW(
                $0,
                DWORD(GENERIC_WRITE) | DWORD(DELETE),
                0,
                nil,
                DWORD(CREATE_NEW),
                DWORD(FILE_ATTRIBUTE_NORMAL),
                nil
            )
        }
        guard let handle, handle != INVALID_HANDLE_VALUE else {
            throw Failure(operation: "create", path: temporary, code: GetLastError())
        }
        var landed = false
        defer {
            if !landed { discard(handle) }
            CloseHandle(handle)
        }
        try writeAll(data, to: handle, path: temporary)
        try FileRetry.attempt(isTransient: isTransient) {
            try rename(handle, to: path)
        }
        landed = true
    }

    private static func writeAll(_ data: Data, to handle: HANDLE, path: String) throws {
        try data.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) in
            guard let base = bytes.baseAddress else { return }
            var written = 0
            while written < bytes.count {
                let chunk = DWORD(min(writeChunk, bytes.count - written))
                var wrote: DWORD = 0
                guard WriteFile(handle, base.advanced(by: written), chunk, &wrote, nil), wrote > 0 else {
                    throw Failure(operation: "write", path: path, code: GetLastError())
                }
                written += Int(wrote)
            }
        }
    }

    /// Renames the open file to `path`, replacing what is there. POSIX semantics first,
    /// which replaces even a file someone has open for reading; the classic rename where
    /// the volume knows no better, which is an SD card.
    private static func rename(_ handle: HANDLE, to path: String) throws {
        let name = Array(path.utf16)
        let nameBytes = name.count * MemoryLayout<WCHAR>.size
        let size = MemoryLayout<FILE_RENAME_INFO>.size + nameBytes + MemoryLayout<WCHAR>.size
        try withUnsafeTemporaryAllocation(byteCount: size, alignment: MemoryLayout<FILE_RENAME_INFO>.alignment) {
            buffer in
            _ = buffer.initializeMemory(as: UInt8.self, repeating: 0)
            let info = buffer.baseAddress!.bindMemory(to: FILE_RENAME_INFO.self, capacity: 1)
            info.pointee.RootDirectory = nil
            info.pointee.FileNameLength = DWORD(nameBytes)
            let nameField = buffer.baseAddress!.advanced(by: MemoryLayout<FILE_RENAME_INFO>.offset(of: \.FileName)!)
            name.withUnsafeBytes { nameField.copyMemory(from: $0.baseAddress!, byteCount: nameBytes) }

            info.pointee.Flags = DWORD(FILE_RENAME_FLAG_POSIX_SEMANTICS) | DWORD(FILE_RENAME_FLAG_REPLACE_IF_EXISTS)
            if SetFileInformationByHandle(handle, FileRenameInfoEx, info, DWORD(size)) { return }
            var code = GetLastError()
            // A read-only destination refuses the replace; POSIX semantics would not.
            if code == DWORD(ERROR_ACCESS_DENIED), clearReadOnly(path) {
                if SetFileInformationByHandle(handle, FileRenameInfoEx, info, DWORD(size)) { return }
                code = GetLastError()
            }
            guard
                code == DWORD(ERROR_NOT_SUPPORTED) || code == DWORD(ERROR_INVALID_PARAMETER)
                    || code == DWORD(ERROR_FILE_SYSTEM_LIMITATION)
            else {
                throw Failure(operation: "replace", path: path, code: code)
            }
            info.pointee.Flags = 0
            info.pointee.ReplaceIfExists = 1
            guard SetFileInformationByHandle(handle, FileRenameInfo, info, DWORD(size)) else {
                throw Failure(operation: "replace", path: path, code: GetLastError())
            }
        }
    }

    /// Clears the read-only attribute; false where there was none to clear.
    private static func clearReadOnly(_ path: String) -> Bool {
        path.withCString(encodedAs: UTF16.self) { wide in
            let attributes = GetFileAttributesW(wide)
            guard attributes != INVALID_FILE_ATTRIBUTES, attributes & DWORD(FILE_ATTRIBUTE_READONLY) != 0 else {
                return false
            }
            return SetFileAttributesW(wide, attributes & ~DWORD(FILE_ATTRIBUTE_READONLY))
        }
    }

    /// Marks the open file for deletion when the handle closes.
    private static func discard(_ handle: HANDLE) {
        var disposition = FILE_DISPOSITION_INFO(DeleteFileA: 1)
        _ = SetFileInformationByHandle(
            handle,
            FileDispositionInfo,
            &disposition,
            DWORD(MemoryLayout<FILE_DISPOSITION_INFO>.size)
        )
    }

    // MARK: Moving

    /// Moves a file or a directory, as `FileManager.moveItem` does: it fails where the
    /// destination exists. A file crosses volumes by copying, which `MoveFileExW` does
    /// itself; a directory it refuses to, answering ERROR_ACCESS_DENIED rather than a code
    /// that says why, so a directory bound for another volume is copied and then removed
    /// here before `MoveFileExW` is asked at all.
    static func move(_ source: URL, to destination: URL) throws {
        let from = source.nativePath
        let to = destination.nativePath
        if isDirectory(from), volume(of: from) != volume(of: destination.deletingLastPathComponent().nativePath) {
            try copyTree(from, to: to)
            try removeTree(from)
            return
        }
        try FileRetry.attempt(isTransient: isTransient) {
            let moved = from.withCString(encodedAs: UTF16.self) { wideFrom in
                to.withCString(encodedAs: UTF16.self) { wideTo in
                    MoveFileExW(wideFrom, wideTo, DWORD(MOVEFILE_COPY_ALLOWED))
                }
            }
            guard moved else { throw Failure(operation: "move", path: to, code: GetLastError()) }
        }
    }

    private static func isDirectory(_ path: String) -> Bool {
        let attributes = path.withCString(encodedAs: UTF16.self) { GetFileAttributesW($0) }
        return attributes != INVALID_FILE_ATTRIBUTES && attributes & DWORD(FILE_ATTRIBUTE_DIRECTORY) != 0
    }

    /// The root of the volume holding `path`, `X:\`, or nil where the system will not say.
    private static func volume(of path: String) -> String? {
        var root = [WCHAR](repeating: 0, count: Int(MAX_PATH))
        let found = path.withCString(encodedAs: UTF16.self) { GetVolumePathNameW($0, &root, DWORD(root.count)) }
        guard found else { return nil }
        return root.withUnsafeBufferPointer { String(decodingCString: $0.baseAddress!, as: UTF16.self) }.lowercased()
    }

    /// Copies a directory tree, failing where the destination exists. A failure midway
    /// takes the partial copy away again.
    private static func copyTree(_ from: String, to: String) throws {
        let made = to.withCString(encodedAs: UTF16.self) { CreateDirectoryW($0, nil) }
        guard made else { throw Failure(operation: "copy", path: to, code: GetLastError()) }
        do {
            for entry in entries(in: from) {
                let landing = to + "\\" + entry.name
                if entry.isDirectory && !entry.isLink {
                    try copyTree(entry.path, to: landing)
                    continue
                }
                let copied = entry.path.withCString(encodedAs: UTF16.self) { wideFrom in
                    landing.withCString(encodedAs: UTF16.self) { wideTo in CopyFileW(wideFrom, wideTo, true) }
                }
                guard copied else { throw Failure(operation: "copy", path: landing, code: GetLastError()) }
            }
        } catch {
            try? removeTree(to)
            throw error
        }
    }

    // MARK: Removing

    /// Removes a file, or a directory and everything in it. A link to a directory is
    /// removed as a link; what it points to is left alone.
    static func remove(_ url: URL) throws {
        try removeTree(url.nativePath)
    }

    private static func removeTree(_ path: String) throws {
        let attributes = path.withCString(encodedAs: UTF16.self) { GetFileAttributesW($0) }
        guard attributes != INVALID_FILE_ATTRIBUTES else {
            throw Failure(operation: "remove", path: path, code: GetLastError())
        }
        let isDirectory = attributes & DWORD(FILE_ATTRIBUTE_DIRECTORY) != 0
        let isLink = attributes & DWORD(FILE_ATTRIBUTE_REPARSE_POINT) != 0
        if isDirectory && !isLink {
            for entry in entries(in: path) { try removeTree(entry.path) }
        }
        if attributes & DWORD(FILE_ATTRIBUTE_READONLY) != 0 { _ = clearReadOnly(path) }
        try FileRetry.attempt(isTransient: isTransient) {
            let removed = path.withCString(encodedAs: UTF16.self) {
                isDirectory ? RemoveDirectoryW($0) : DeleteFileW($0)
            }
            guard removed else { throw Failure(operation: "remove", path: path, code: GetLastError()) }
        }
    }

    // MARK: Walking

    private struct Entry {
        let name: String
        let path: String
        let isDirectory: Bool
        let isLink: Bool
    }

    /// Everything directly inside a directory.
    private static func entries(in directory: String) -> [Entry] {
        var found = WIN32_FIND_DATAW()
        let search = (directory + "\\*").withCString(encodedAs: UTF16.self) { FindFirstFileW($0, &found) }
        guard let search, search != INVALID_HANDLE_VALUE else { return [] }
        defer { FindClose(search) }
        var out: [Entry] = []
        repeat {
            let name = withUnsafePointer(to: &found.cFileName) {
                $0.withMemoryRebound(to: WCHAR.self, capacity: Int(MAX_PATH)) {
                    String(decodingCString: $0, as: UTF16.self)
                }
            }
            guard name != "." && name != ".." else { continue }
            out.append(
                Entry(
                    name: name,
                    path: directory + "\\" + name,
                    isDirectory: found.dwFileAttributes & DWORD(FILE_ATTRIBUTE_DIRECTORY) != 0,
                    isLink: found.dwFileAttributes & DWORD(FILE_ATTRIBUTE_REPARSE_POINT) != 0
                )
            )
        } while FindNextFileW(search, &found)
        return out
    }
}
#endif
