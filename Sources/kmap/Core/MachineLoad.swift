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
        let cpu = previous.flatMap { was in ticks.flatMap { rate(from: was, to: $0) } }
        return (MachineLoad(cpu: cpu, usedMemory: memory.used, totalMemory: memory.total),
                ticks)
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
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info>.size
                                           / MemoryLayout<integer_t>.size)
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

    /// Used memory as wired, active and compressed pages. Purgeable and file-backed
    /// pages are excluded, being reclaimable on demand.
    private static func readMemory() -> (used: UInt64, total: UInt64) {
        let total = ProcessInfo.processInfo.physicalMemory
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size
                                           / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return (0, total) }
        let page = UInt64(vm_kernel_page_size)
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
