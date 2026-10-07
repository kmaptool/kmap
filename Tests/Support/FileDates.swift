import Foundation

@testable import kmap

#if os(Windows)
import WinSDK
#endif

/// Sets when a file or a folder last changed. Foundation on Windows opens a folder without
/// FILE_FLAG_BACKUP_SEMANTICS and is refused, so there the system is asked itself.
enum FileDates {
    #if os(Windows)
    /// Seconds from 1601, where a FILETIME counts from, to 1970.
    private static let fromFileTimeEpoch: Double = 11_644_473_600
    /// A FILETIME counts in 100 ns.
    private static let ticksPerSecond: Double = 10_000_000
    #endif

    static func setModified(_ url: URL, to date: Date) throws {
        #if os(Windows)
        let handle = url.nativePath.withCString(encodedAs: UTF16.self) {
            CreateFileW(
                $0,
                DWORD(FILE_WRITE_ATTRIBUTES),
                DWORD(FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE),
                nil,
                DWORD(OPEN_EXISTING),
                DWORD(FILE_FLAG_BACKUP_SEMANTICS),
                nil
            )
        }
        guard let handle, handle != INVALID_HANDLE_VALUE else { throw CocoaError(.fileWriteNoPermission) }
        defer { CloseHandle(handle) }
        let ticks = UInt64((date.timeIntervalSince1970 + fromFileTimeEpoch) * ticksPerSecond)
        var time = FILETIME(dwLowDateTime: DWORD(truncatingIfNeeded: ticks), dwHighDateTime: DWORD(ticks >> 32))
        guard SetFileTime(handle, nil, nil, &time) else { throw CocoaError(.fileWriteNoPermission) }
        #else
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: url.path)
        #endif
    }
}
