import Foundation

#if canImport(Darwin)
import Darwin
#elseif os(Windows)
import WinSDK
#endif

/// Current load of the whole machine, not of this process, since most of a build runs
/// in child processes.
///
/// CPU is a rate and needs two samples, so the first reading is nil rather than zero.
struct MachineLoad {
    /// Busy fraction of the whole machine since the previous sample, 0...1.
    var cpu: Double?
    /// Bytes in use, and what the machine has.
    var usedMemory: UInt64
    var totalMemory: UInt64

    var memoryFraction: Double {
        totalMemory > 0 ? Double(usedMemory) / Double(totalMemory) : 0
    }

    /// Reads the machine's load.
    ///
    /// - Parameter previous: The ticks from the last call, or nil on the first.
    /// - Returns: The load, and the ticks to pass back next time.
    static func read(since previous: Ticks?) -> (load: MachineLoad, ticks: Ticks?) {
        let ticks = readTicks()
        let memory = readMemory()
        // Windows is asked for the figure its Task Manager shows; busy time elsewhere, and
        // there too where that figure cannot be had.
        // Read on the first call too, which sets its starting point.
        let utility = readUtility()
        let cpu = previous.flatMap { was in utility ?? ticks.flatMap { rate(from: was, to: $0) } }
        return (
            MachineLoad(cpu: cpu, usedMemory: memory.used, totalMemory: memory.total),
            ticks
        )
    }

    /// Returns the busy fraction between two readings, or nil where the counters did not
    /// advance — two reads inside one tick, or a wrap.
    static func rate(from previous: Ticks, to now: Ticks) -> Double? {
        guard now.total > previous.total, now.busy >= previous.busy else { return nil }
        let busy = Double(now.busy - previous.busy)
        let total = Double(now.total - previous.total)
        return min(1, max(0, busy / total))
    }

    /// Cumulative CPU time counters since boot, in the platform's own units.
    struct Ticks: Equatable {
        var busy: UInt64
        var total: UInt64
    }

    // MARK: Reading the machine

    #if canImport(Darwin)
    private static func readTicks() -> Ticks? {
        var info = host_cpu_load_info()
        var count = mach_msg_type_number_t(
            MemoryLayout<host_cpu_load_info>.size
                / MemoryLayout<integer_t>.size
        )
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        let user = UInt64(info.cpu_ticks.0), system = UInt64(info.cpu_ticks.1)
        let idle = UInt64(info.cpu_ticks.2), nice = UInt64(info.cpu_ticks.3)
        let busy = user &+ system &+ nice
        return Ticks(busy: busy, total: busy &+ idle)
    }

    static func readUtility() -> Double? { nil }

    /// Used memory as wired, active and compressed pages. Purgeable and file-backed
    /// pages are excluded, being reclaimable on demand.
    private static func readMemory() -> (used: UInt64, total: UInt64) {
        let total = ProcessInfo.processInfo.physicalMemory
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(
            MemoryLayout<vm_statistics64>.size
                / MemoryLayout<integer_t>.size
        )
        let result = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return (0, total) }
        // Asked of the host rather than read from the global the headers export: the counts
        // are in the kernel's pages, and the global is a mutable C variable.
        var pageSize: vm_size_t = 0
        guard host_page_size(mach_host_self(), &pageSize) == KERN_SUCCESS else { return (0, total) }
        let page = UInt64(pageSize)
        let wired = UInt64(stats.wire_count) * page
        let active = UInt64(stats.active_count) * page
        let compressed = UInt64(stats.compressor_page_count) * page
        return (wired + active + compressed, total)
    }
    #elseif os(Windows)
    /// The whole machine's time since boot, in 100-nanosecond units.
    ///
    /// `GetSystemTimes` includes idle within the kernel figure, so kernel + user is the
    /// total and idle is subtracted from it rather than added.
    private static func readTicks() -> Ticks? {
        var idle = FILETIME(), kernel = FILETIME(), user = FILETIME()
        guard GetSystemTimes(&idle, &kernel, &user) else { return nil }
        let total = hundredNanoseconds(kernel) &+ hundredNanoseconds(user)
        let free = hundredNanoseconds(idle)
        return Ticks(busy: total >= free ? total - free : 0, total: total)
    }

    private static func hundredNanoseconds(_ time: FILETIME) -> UInt64 {
        UInt64(time.dwHighDateTime) << 32 | UInt64(time.dwLowDateTime)
    }

    /// The load as Task Manager shows it since the previous call; nil where it cannot be had.
    static func readUtility() -> Double? { ProcessorUtility.read() }

    /// Used memory: total physical less what is available.
    private static func readMemory() -> (used: UInt64, total: UInt64) {
        var status = MEMORYSTATUSEX()
        status.dwLength = DWORD(MemoryLayout<MEMORYSTATUSEX>.size)
        guard GlobalMemoryStatusEx(&status) else {
            return (0, ProcessInfo.processInfo.physicalMemory)
        }
        let total = status.ullTotalPhys
        let available = status.ullAvailPhys
        return (total >= available ? total - available : 0, total)
    }
    #else
    private static func readTicks() -> Ticks? {
        guard let text = try? String(contentsOfFile: "/proc/stat", encoding: .utf8),
            let line = text.split(separator: "\n").first(where: { $0.hasPrefix("cpu ") })
        else { return nil }
        let fields = line.split(separator: " ").dropFirst().compactMap { UInt64($0) }
        // user nice system idle iowait irq softirq steal …
        guard fields.count >= 4 else { return nil }
        let idle = fields[3] + (fields.count > 4 ? fields[4] : 0)
        let total = fields.reduce(0, &+)
        return Ticks(busy: total >= idle ? total - idle : 0, total: total)
    }

    static func readUtility() -> Double? { nil }

    /// Used memory from `MemTotal` less `MemAvailable`, the kernel's estimate of what a
    /// new program could get without swapping; `MemFree` counts far less.
    private static func readMemory() -> (used: UInt64, total: UInt64) {
        guard let text = try? String(contentsOfFile: "/proc/meminfo", encoding: .utf8)
        else { return (0, ProcessInfo.processInfo.physicalMemory) }
        var values: [String: UInt64] = [:]
        for line in text.split(separator: "\n") {
            let parts = line.split(separator: ":")
            guard parts.count == 2,
                let kilobytes = UInt64(parts[1].split(separator: " ").first ?? "")
            else { continue }
            values[String(parts[0])] = kilobytes * 1024
        }
        let total = values["MemTotal"] ?? ProcessInfo.processInfo.physicalMemory
        let available = values["MemAvailable"] ?? values["MemFree"] ?? 0
        return (total >= available ? total - available : 0, total)
    }
    #endif
}

#if os(Windows)
/// `% Processor Utility`, the load Task Manager shows: busy time weighed by the clock
/// speed it ran at, so on a processor that speeds up under load it reads above plain
/// busy time. Asked of pdh.dll, found by name at run time: the SDK module leaves it out.
private enum ProcessorUtility {
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
