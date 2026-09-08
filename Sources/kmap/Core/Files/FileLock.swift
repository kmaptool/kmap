import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif os(Windows)
import WinSDK
import ucrt
#endif

/// An advisory cross-process lock over a directory that two runs might rewrite.
///
/// `flock` on the Unixes; `LockFileEx` on Windows, which locks the first byte as a range
/// rather than the file. The handle is owned here, so the lock is released on a throw.
struct FileLock {

    /// Runs `body` with `file` held exclusively against other processes.
    ///
    /// - Note: Advisory, and it constrains only other kmap processes. If the lock file
    ///   cannot be opened, `body` runs unlocked.
    static func holding<T>(_ file: URL, _ body: () throws -> T) rethrows -> T {
        #if os(Windows)
        // Shared open modes, so a second process waits on the lock rather than
        // failing to open the file.
        let handle = file.nativePath.withCString(encodedAs: UTF16.self) { path in
            CreateFileW(path, DWORD(GENERIC_READ) | DWORD(GENERIC_WRITE),
                        DWORD(FILE_SHARE_READ) | DWORD(FILE_SHARE_WRITE), nil,
                        DWORD(OPEN_ALWAYS), DWORD(FILE_ATTRIBUTE_NORMAL), nil)
        }
        guard let handle, handle != INVALID_HANDLE_VALUE else { return try body() }
        defer { CloseHandle(handle) }
        var overlapped = OVERLAPPED()
        let locked = LockFileEx(handle, DWORD(LOCKFILE_EXCLUSIVE_LOCK), 0, 1, 0, &overlapped)
        defer {
            if locked {
                var releasing = OVERLAPPED()
                UnlockFileEx(handle, 0, 1, 0, &releasing)
            }
        }
        return try body()
        #else
        let descriptor = open(file.nativePath, O_CREAT | O_RDWR, 0o644)
        guard descriptor >= 0 else { return try body() }
        defer {
            flock(descriptor, LOCK_UN)
            close(descriptor)
        }
        flock(descriptor, LOCK_EX)
        return try body()
        #endif
    }
}
