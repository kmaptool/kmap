import Foundation
#if os(Windows)
import WinSDK
#endif

/// The resources available to this process, and the concurrency they allow. Every
/// call site takes its limits from here.
enum Machine {
    /// Cores available to this process, not the cores the chip has: a quality-of-service
    /// class or a container CPU quota lowers it.
    static var cores: Int {
        #if os(Windows)
        // Foundation's count has been the first processor group's before now, which is a
        // quarter of the machine on a big one and wrong on a small one. Ask Windows.
        // 0xffff is ALL_PROCESSOR_GROUPS, written out because the macro is not imported.
        let active = Int(GetActiveProcessorCount(WORD(0xffff)))
        if active > 0 { return active }
        #endif
        return max(1, ProcessInfo.processInfo.activeProcessorCount)
    }

    /// Performance cores, where the platform distinguishes them; `cores` elsewhere.
    ///
    /// For work that is latency-bound on a few lanes. Throughput work uses `cores`,
    /// since an efficiency core finishing late still beats a job never started.
    static let fastCores: Int = {
        #if canImport(Darwin)
        var count: Int32 = 0
        var size = MemoryLayout<Int32>.size
        if sysctlbyname("hw.perflevel0.logicalcpu", &count, &size, nil, 0) == 0, count > 0 {
            return min(Int(count), cores)
        }
        #endif
        return cores
    }()

    /// Returns how many tiles to compile at once: no more than the tiles, the cores, or
    /// the gigabytes of heap to spare.
    ///
    /// The jobs share one JVM heap and hold about a gigabyte of live data each at
    /// `referenceNodesPerTile`, scaling with `nodesPerTile`.
    static func compileJobs(tiles: Int, heapGB: Int, nodesPerTile: Int) -> Int {
        let perJobGB = max(1.0, Double(nodesPerTile) / Double(referenceNodesPerTile))
        let byHeap = Int((Double(max(1, heapGB)) - 1) / perJobGB)
        return max(1, min(tiles, cores, max(1, byHeap)))
    }

    /// The tile size the per-job heap figure above applies at.
    private static let referenceNodesPerTile = 1_200_000

    /// Memory this build may use, in whole gigabytes: physical memory, or the smaller
    /// figure given by `KMAP_MEMORY_GB` or `told(_:)`.
    static var memoryGB: Int {
        gate.lock()
        defer { gate.unlock() }
        if let said { return said }
        if let told = ProcessInfo.processInfo.environment["KMAP_MEMORY_GB"],
           let gigabytes = Int(told), gigabytes > 0 {
            said = gigabytes
            return gigabytes
        }
        said = physicalGB
        return physicalGB
    }

    /// The machine's memory in whole gigabytes, asked of the system directly on Windows,
    /// where Foundation has answered zero — which would leave every queue at its floor.
    private static var physicalGB: Int {
        #if os(Windows)
        var status = MEMORYSTATUSEX()
        status.dwLength = DWORD(MemoryLayout<MEMORYSTATUSEX>.size)
        if GlobalMemoryStatusEx(&status), status.ullTotalPhys > 0 {
            return max(1, Int(status.ullTotalPhys / 1_073_741_824))
        }
        #endif
        return max(1, Int(ProcessInfo.processInfo.physicalMemory / 1_073_741_824))
    }

    /// Sets the memory figure for this run. Written once before a build starts and read
    /// from every queue, so it is guarded by `gate`.
    static func told(_ gigabytes: Int) {
        gate.lock()
        said = max(1, gigabytes)
        gate.unlock()
    }

    private static let gate = NSLock()
    nonisolated(unsafe) private static var said: Int?

    /// Returns how many workers holding `gigabytes` each may run at once: `wanted`,
    /// capped by half of memory, and never fewer than one.
    ///
    /// Half rather than all, since the per-worker figure is typical rather than a worst
    /// case and swapping costs more than serialising.
    static func lanes(_ wanted: Int, holdingEach gigabytes: Double,
                      memoryGB: Int = Machine.memoryGB) -> Int {
        guard gigabytes > 0 else { return max(1, wanted) }
        let byMemory = Int(Double(memoryGB) / 2 / gigabytes)
        return max(1, min(wanted, byMemory))
    }

    /// Workers for a decode pass, capped where the file can no longer feed more of them.
    static var readers: Int { min(cores, 16) }

    /// Workers for a pass holding a buffer each, leaving the reader feeding them and the
    /// writer draining them a core apiece — but only one core on a small machine, where
    /// two of four cores held back is half the machine idle.
    static var workers: Int { max(1, cores - (cores > 4 ? 2 : 1)) }

    /// The high-water mark of this process's resident memory, in bytes; zero where the
    /// system will not say.
    static func memoryInUse() -> Int64 {
        #if os(Windows)
        // Windows has no `rusage`; `PeakWorkingSetSize` is the same mark. The K32
        // spelling lives in kernel32, so no psapi.lib is needed on the link line.
        var counters = PROCESS_MEMORY_COUNTERS()
        counters.cb = DWORD(MemoryLayout<PROCESS_MEMORY_COUNTERS>.size)
        guard K32GetProcessMemoryInfo(GetCurrentProcess(), &counters, counters.cb) else {
            return 0
        }
        return Int64(counters.PeakWorkingSetSize)
        #else
        var usage = rusage()
        // Glibc declares `who` as an enum and Darwin as a plain int.
        #if canImport(Darwin)
        let ok = getrusage(RUSAGE_SELF, &usage) == 0
        #else
        let ok = getrusage(RUSAGE_SELF.rawValue, &usage) == 0
        #endif
        guard ok else { return 0 }
        // Darwin reports bytes here, Linux kilobytes.
        #if canImport(Darwin)
        return Int64(usage.ru_maxrss)
        #else
        return Int64(usage.ru_maxrss) * 1024
        #endif
        #endif
    }
}

/// Timing lines about kmap's own work, printed in a debug build or when `KMAP_TIMING`
/// is set, and suppressed otherwise.
enum Measured {
    /// Read once, since this is consulted from the paths it measures.
    private static let asked =
        ProcessInfo.processInfo.environment["KMAP_TIMING"] != nil

    static var reported: Bool {
        #if DEBUG
        return true
        #else
        return asked
        #endif
    }

    /// Returns a timing line for `what`, or nil when timing is off or the elapsed time
    /// is under `atLeast` seconds.
    static func line(_ what: String, since: Date, atLeast: Double = 0.2) -> String? {
        guard reported else { return nil }
        let seconds = Date().timeIntervalSince(since)
        guard seconds >= atLeast else { return nil }
        return String(format: "  %@ %.1f s, up to %@", what, seconds,
                      Fmt.bytes(Machine.memoryInUse()))
    }
}
