import Foundation

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif os(Windows)
import WinSDK
import ucrt
#endif

/// What Foundation does not answer the same way on every platform about running a child:
/// how to wait for it, how to insist that it stop, and how to read what is waiting in a
/// pipe without blocking for more. The rest of `Process` is portable.
enum ChildProcess {
    /// Grace after `terminate()`, and the poll step.
    static let exitGrace: TimeInterval = 2
    private static let pollInterval: TimeInterval = 0.02

    /// Polls instead of `waitUntilExit()`, which deadlocks on the main thread on Linux.
    /// True once the process has exited.
    @discardableResult
    static func waitForExit(_ process: Process, within: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(within)
        while process.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: pollInterval)
        }
        return !process.isRunning
    }

    /// The tools running now, for a kmap that is made to leave to stop first: each runs in
    /// a process group of its own, which a closed terminal's hang-up does not reach. Each
    /// with whether it is signalled alone (see `track`), under the same lock.
    private static let live = Locked<[ObjectIdentifier: (process: Process, alone: Bool)]>([:])

    /// Set once kmap is on its way out, for good: see `leave`.
    private static let leaving = Locked(false)

    static var isLeaving: Bool { leaving.withLock { $0 } }

    /// Takes the leave back, for a test that left: kmap itself never comes back.
    static func stayForTests() { leaving.withLock { $0 = false } }

    /// A tool started while kmap is leaving is killed at once.
    ///
    /// - Parameter alone: signal the tool, not its group: dpkg under apt finishes.
    static func track(_ process: Process, alone: Bool = false) {
        live.withLock { $0[ObjectIdentifier(process)] = (process, alone) }
        if isLeaving { insist(on: process) }
    }

    static func untrack(_ process: Process) {
        _ = live.withLock { $0.removeValue(forKey: ObjectIdentifier(process)) }
    }

    private static func isAlone(_ process: Process) -> Bool {
        live.withLock { $0[ObjectIdentifier(process)]?.alone ?? false }
    }

    /// Stops every tool on kmap's way out, and every one started after: work not told it
    /// is ending may start the next tool before the process ends.
    static func leave(grace: TimeInterval = exitGrace) {
        leaving.withLock { $0 = true }
        stopAll(grace: grace)
    }

    /// Stops every tool still running: all asked at once, then SIGKILL after the grace.
    static func stopAll(grace: TimeInterval = exitGrace) {
        // Read once, with how each is signalled: one that ends in the grace is untracked.
        let running = live.withLock { Array($0.values) }.filter(\.process.isRunning)
        for tool in running { ask(tool.process, alone: tool.alone) }
        let deadline = Date().addingTimeInterval(grace)
        while running.contains(where: \.process.isRunning), Date() < deadline {
            Thread.sleep(forTimeInterval: pollInterval)
        }
        for tool in running { insist(on: tool.process, alone: tool.alone) }
    }

    /// Terminate, `exitGrace`, then SIGKILL.
    static func stop(_ process: Process) {
        ask(process)
        if !waitForExit(process, within: exitGrace) {
            insist(on: process)
            waitForExit(process, within: exitGrace)
        }
    }

    /// Stop it, having already asked politely.
    ///
    /// `Process.terminate()` sends SIGTERM on the Unixes, which a program may handle or
    /// ignore; SIGKILL it cannot. On Windows `terminate()` is already `TerminateProcess`,
    /// which is not refusable, and there are no signals.
    static func insist(on process: Process, alone: Bool? = nil) {
        #if os(Windows)
        if process.isRunning { process.terminate() }
        #else
        let single = alone ?? isAlone(process)
        if process.isRunning {
            signalGroup(of: process, SIGKILL, alone: single)
        } else if process.processIdentifier > 0, !single {
            // A leader gone may leave what it forked: its group, never its own pid alone.
            // The pid is not given out again while the group lives.
            kill(-process.processIdentifier, SIGKILL)
        }
        #endif
    }

    /// Asks it to stop: SIGTERM, which a program may handle, on the Unixes.
    static func ask(_ process: Process, alone: Bool? = nil) {
        #if os(Windows)
        if process.isRunning { process.terminate() }
        #else
        if process.isRunning { signalGroup(of: process, SIGTERM, alone: alone ?? isAlone(process)) }
        #endif
    }

    #if !os(Windows)
    /// The tool's group, which holds what it forks; the tool alone where it leads none or
    /// was tracked `alone`.
    private static func signalGroup(of process: Process, _ number: Int32, alone single: Bool) {
        let pid = process.processIdentifier
        guard pid > 0 else { return }
        if single || kill(-pid, number) != 0 { kill(pid, number) }
    }
    #endif

    /// Somewhere for a child's standard input to come from, with nothing in it, so a tool
    /// that asks a question meets an immediate end of input rather than the raw-mode terminal.
    ///
    /// `FileHandle.nullDevice` is wrong on Windows: Foundation answers reads and writes
    /// itself, so a grandchild inherits no real handle. `NUL` is the actual device.
    static var emptyInput: FileHandle {
        #if os(Windows)
        return FileHandle(forReadingAtPath: "NUL") ?? FileHandle.nullDevice
        #else
        return FileHandle.nullDevice
        #endif
    }

    /// Somewhere for a child's output to go when nothing is reading it, for the same reason.
    static var discardedOutput: FileHandle {
        #if os(Windows)
        return FileHandle(forWritingAtPath: "NUL") ?? FileHandle.nullDevice
        #else
        return FileHandle.nullDevice
        #endif
    }

    /// Whatever is sitting in the pipe right now, without waiting for more.
    ///
    /// A pipe stays open as long as anything holds its writing end, including a grandchild
    /// the child left behind, so reading to end of file can block indefinitely. Both
    /// platforms read only what is available: POSIX by `O_NONBLOCK`, Windows by
    /// `PeekNamedPipe`, there being no non-blocking mode for a pipe there.
    static func readWhatIsWaiting(
        _ handle: FileHandle,
        into ingest: (ArraySlice<UInt8>) -> Void
    ) {
        #if os(Windows)
        let pipe = handle._handle
        guard pipe != INVALID_HANDLE_VALUE else { return }
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            var waiting: DWORD = 0
            guard PeekNamedPipe(pipe, nil, 0, nil, &waiting, nil), waiting > 0 else { return }
            var read: DWORD = 0
            let wanted = DWORD(min(Int(waiting), buffer.count))
            let ok = buffer.withUnsafeMutableBytes {
                ReadFile(pipe, $0.baseAddress, wanted, &read, nil)
            }
            guard ok, read > 0 else { return }
            ingest(buffer[0..<Int(read)])
        }
        #else
        let descriptor = handle.fileDescriptor
        let flags = fcntl(descriptor, F_GETFL, 0)
        guard flags != -1, fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) != -1 else { return }
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let count = buffer.withUnsafeMutableBytes { raw in
                read(descriptor, raw.baseAddress, raw.count)
            }
            guard count > 0 else { return }  // 0 is end of file, -1 is "nothing waiting"
            ingest(buffer[0..<count])
        }
        #endif
    }
}
