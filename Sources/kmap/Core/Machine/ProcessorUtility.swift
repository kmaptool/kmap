#if os(Windows)
import Foundation
import WinSDK

/// `% Processor Utility`, the load Task Manager shows: busy time weighed by the clock
/// speed it ran at, so on a processor that speeds up under load it reads above plain
/// busy time. Asked of pdh.dll, found by name at run time: the SDK module leaves it out.
enum ProcessorUtility {
    private typealias Open = @convention(c) (UnsafePointer<WCHAR>?, UInt, UnsafeMutablePointer<UInt>) -> Int32
    private typealias Add = @convention(c) (UInt, UnsafePointer<WCHAR>, UInt, UnsafeMutablePointer<UInt>) -> Int32
    private typealias Collect = @convention(c) (UInt) -> Int32
    private typealias Format =
        @convention(c) (UInt, DWORD, UnsafeMutablePointer<DWORD>?, UnsafeMutableRawPointer) -> Int32

    /// An open query and its 1 counter; the handles are kept as the numbers they are.
    private struct Query {
        let query: UInt
        let counter: UInt
        let collect: Collect
        let format: Format
    }

    private static let counterPath = "\\Processor Information(_Total)\\% Processor Utility"
    /// LOAD_LIBRARY_SEARCH_SYSTEM32: only the system's own pdh.dll is taken.
    private static let systemOnly: DWORD = 0x800
    /// PDH_FMT_DOUBLE, and the size of PDH_FMT_COUNTERVALUE: a status, then the number.
    private static let asDouble: DWORD = 0x200
    private static let valueSize = 16, numberOffset = 8
    /// PDH_CSTATUS_VALID_DATA and PDH_CSTATUS_NEW_DATA.
    private static let goodStatuses: Set<DWORD> = [0, 1]

    /// Opened on first use and kept for the life of the process; nil where the counter
    /// cannot be had.
    private static let query: Query? = {
        let library = "pdh.dll".withCString(encodedAs: UTF16.self) { LoadLibraryExW($0, nil, systemOnly) }
        guard let library,
            let open = GetProcAddress(library, "PdhOpenQueryW"),
            let add = GetProcAddress(library, "PdhAddEnglishCounterW"),
            let collect = GetProcAddress(library, "PdhCollectQueryData"),
            let format = GetProcAddress(library, "PdhGetFormattedCounterValue")
        else { return nil }
        var query: UInt = 0, counter: UInt = 0
        guard unsafeBitCast(open, to: Open.self)(nil, 0, &query) == 0 else { return nil }
        let added = counterPath.withCString(encodedAs: UTF16.self) {
            unsafeBitCast(add, to: Add.self)(query, $0, 0, &counter)
        }
        guard added == 0 else { return nil }
        let made = Query(
            query: query,
            counter: counter,
            collect: unsafeBitCast(collect, to: Collect.self),
            format: unsafeBitCast(format, to: Format.self)
        )
        // A rate: the first reading only sets the starting point.
        _ = made.collect(made.query)
        return made
    }()

    /// The busy fraction since the previous call, 0...1; nil until there are 2 readings.
    static func read() -> Double? {
        guard let query, query.collect(query.query) == 0 else { return nil }
        var value = [UInt8](repeating: 0, count: valueSize)
        let status = value.withUnsafeMutableBytes { query.format(query.counter, asDouble, nil, $0.baseAddress!) }
        guard status == 0 else { return nil }
        let (state, percent) = value.withUnsafeBytes {
            ($0.load(as: DWORD.self), $0.load(fromByteOffset: numberOffset, as: Double.self))
        }
        guard goodStatuses.contains(state), percent.isFinite else { return nil }
        return min(1, max(0, percent / 100))
    }
}
#endif
