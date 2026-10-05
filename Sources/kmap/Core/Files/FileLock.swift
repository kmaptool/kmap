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
            CreateFileW(
                path,
                DWORD(GENERIC_READ) | DWORD(GENERIC_WRITE),
                DWORD(FILE_SHARE_READ) | DWORD(FILE_SHARE_WRITE),
                nil,
                DWORD(OPEN_ALWAYS),
                DWORD(FILE_ATTRIBUTE_NORMAL),
                nil
            )
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

/// A cross-process lock taken only where it is free, and held while this value lives:
/// for work that must not run twice at once and should say so rather than wait.
final class HeldLock: @unchecked Sendable {
    #if os(Windows)
    private let handle: HANDLE?
    #else
    private let descriptor: Int32
    #endif

    /// Nil where another process holds `file`. Where the lock file cannot be opened at
    /// all the work goes ahead unlocked, as `FileLock.holding` does.
    init?(trying file: URL) {
        #if os(Windows)
        let opened = file.nativePath.withCString(encodedAs: UTF16.self) { path in
            CreateFileW(
                path,
                DWORD(GENERIC_READ) | DWORD(GENERIC_WRITE),
                DWORD(FILE_SHARE_READ) | DWORD(FILE_SHARE_WRITE),
                nil,
                DWORD(OPEN_ALWAYS),
                DWORD(FILE_ATTRIBUTE_NORMAL),
                nil
            )
        }
        guard let opened, opened != INVALID_HANDLE_VALUE else {
            handle = nil
            return
        }
        var overlapped = OVERLAPPED()
        let flags = DWORD(LOCKFILE_EXCLUSIVE_LOCK) | DWORD(LOCKFILE_FAIL_IMMEDIATELY)
        guard LockFileEx(opened, flags, 0, 1, 0, &overlapped) else {
            let busy = GetLastError() == DWORD(ERROR_LOCK_VIOLATION)
            CloseHandle(opened)
            if busy { return nil }
            handle = nil
            return
        }
        handle = opened
        #else
        // Not inherited, or a tool this run starts would keep the lock after it ends.
        let opened = open(file.nativePath, O_CREAT | O_RDWR | O_CLOEXEC, 0o644)
        guard opened >= 0, flock(opened, LOCK_EX | LOCK_NB) != 0 else {
            descriptor = opened
            return
        }
        let busy = errno == EWOULDBLOCK
        close(opened)
        if busy { return nil }
        descriptor = -1
        #endif
    }

    deinit {
        #if os(Windows)
        if let handle {
            var releasing = OVERLAPPED()
            UnlockFileEx(handle, 0, 1, 0, &releasing)
            CloseHandle(handle)
        }
        #else
        if descriptor >= 0 {
            flock(descriptor, LOCK_UN)
            close(descriptor)
        }
        #endif
    }
}
