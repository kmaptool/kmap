import Foundation

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif os(Windows)
import WinSDK
import ucrt
#endif

/// A cross-process lock taken only where it is free, and held while this value lives:
/// for work that must not run twice at once and should say so rather than wait.
final class HeldLock: @unchecked Sendable {
    #if os(Windows)
    private let handle: HANDLE?
    #else
    private let descriptor: Int32
    #endif
    /// Whether the lock file would not open for want of rights: one another user left.
    private(set) var refused = false

    /// Nil where another process holds `file`, or holds it alone where `shared`: shared
    /// holders keep out only one that would hold it alone. Where the lock file cannot be
    /// opened at all the work goes ahead unlocked, as `FileLock.holding` does.
    init?(trying file: URL, shared: Bool = false) {
        #if os(Windows)
        // The error read at once, before anything else can reset it.
        func open(_ access: DWORD) -> (HANDLE?, DWORD) {
            file.nativePath.withCString(encodedAs: UTF16.self) { path in
                let handle = CreateFileW(
                    path,
                    access,
                    DWORD(FILE_SHARE_READ) | DWORD(FILE_SHARE_WRITE),
                    nil,
                    DWORD(OPEN_ALWAYS),
                    DWORD(FILE_ATTRIBUTE_NORMAL),
                    nil
                )
                return (handle, GetLastError())
            }
        }
        // Another user's lock file opens only to read, which is enough to lock. One being deleted
        // refuses both for a moment and is asked again, or 2 runs would go ahead unlocked.
        func take() -> (HANDLE?, DWORD) {
            let (handle, failure) = open(DWORD(GENERIC_READ) | DWORD(GENERIC_WRITE))
            guard handle == nil || handle == INVALID_HANDLE_VALUE, failure == DWORD(ERROR_ACCESS_DENIED) else {
                return (handle, failure)
            }
            let (reading, readFailure) = open(DWORD(GENERIC_READ))
            return reading != nil && reading != INVALID_HANDLE_VALUE ? (reading, 0) : (reading, readFailure)
        }
        var (opened, failure) = take()
        for _ in 0..<8 where opened == nil || opened == INVALID_HANDLE_VALUE {
            guard failure == DWORD(ERROR_ACCESS_DENIED) || failure == DWORD(ERROR_SHARING_VIOLATION) else { break }
            Sleep(25)
            (opened, failure) = take()
        }
        guard let opened, opened != INVALID_HANDLE_VALUE else {
            refused = failure == DWORD(ERROR_ACCESS_DENIED)
            handle = nil
            return
        }
        var overlapped = OVERLAPPED()
        let flags = (shared ? 0 : DWORD(LOCKFILE_EXCLUSIVE_LOCK)) | DWORD(LOCKFILE_FAIL_IMMEDIATELY)
        guard LockFileEx(opened, flags, 0, 1, 0, &overlapped) else {
            let busy = GetLastError() == DWORD(ERROR_LOCK_VIOLATION)
            CloseHandle(opened)
            if busy { return nil }
            handle = nil
            return
        }
        handle = opened
        // Its time says when it was last taken: a sweep of old locks leaves one in use.
        var now = FILETIME()
        GetSystemTimeAsFileTime(&now)
        SetFileTime(opened, nil, nil, &now)
        #else
        // A lock file removed between the open and the lock is locked by nobody else: the
        // one now under that name is opened again, busy or not.
        func moved(_ opened: Int32) -> Bool {
            var held = stat()
            var named = stat()
            guard fstat(opened, &held) == 0 else { return false }
            if stat(file.nativePath, &named) != 0 { return errno == ENOENT }
            return held.st_dev != named.st_dev || held.st_ino != named.st_ino
        }
        var attempt = 0
        while true {
            attempt += 1
            // Not inherited, or a tool this run starts would keep the lock after it ends.
            var opened = open(file.nativePath, O_CREAT | O_RDWR | O_CLOEXEC, 0o644)
            // Another user's lock file opens to read, and a read is enough to lock: a hold
            // of theirs is seen, not taken for a leftover.
            if opened < 0, errno == EACCES { opened = open(file.nativePath, O_RDONLY | O_CLOEXEC) }
            guard opened >= 0 else {
                refused = errno == EACCES || errno == EPERM
                break
            }
            guard flock(opened, (shared ? LOCK_SH : LOCK_EX) | LOCK_NB) == 0 else {
                let busy = errno == EWOULDBLOCK
                let again = busy && attempt < 8 && moved(opened)
                close(opened)
                if again { continue }
                if busy { return nil }
                break
            }
            if attempt < 8, moved(opened) {
                close(opened)
                continue
            }
            // Its time says when it was last taken: a sweep of old locks leaves one in use.
            futimens(opened, nil)
            descriptor = opened
            return
        }
        descriptor = -1
        #endif
    }

    /// Whether the lock is held, not gone ahead without it as a file that would not open
    /// lets the work do. Whatever removes things asks.
    var isHeld: Bool {
        #if os(Windows)
        handle != nil
        #else
        descriptor >= 0
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

extension HeldLock {
    /// Waits for `file` and holds it. Nil once the task is cancelled.
    static func waiting(for file: URL, shared: Bool = false) async -> HeldLock? {
        while !Task.isCancelled {
            if let lock = HeldLock(trying: file, shared: shared) { return lock }
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
        return nil
    }
}
