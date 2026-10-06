import Foundation

#if os(Windows)
import WinSDK
#endif

/// Ctrl+C, a polite kill and a closed terminal cancel the running work, so its tools stop
/// and the output ends with its last event. A second Ctrl+C leaves at once, tools too. On
/// Windows a closed console ends kmap at once, its tools getting the same close.
extension CLI {
    /// What an interrupt does: the first cancels, the next Ctrl+C exits.
    nonisolated(unsafe) private static var onInterrupt: (@Sendable () -> Void)?
    nonisolated(unsafe) private static var interrupted = false

    /// - Parameter forcing: whether a repeat leaves at once. Only Ctrl+C: a closed
    ///   terminal sends its hang-up twice, from the shell and from the kernel.
    private static func interrupt(forcing: Bool) {
        if interrupted, forcing {
            ChildProcess.leave(grace: 0)
            // `exit` skips the defer that puts the console's code page back.
            ConsoleCodePage.restoreFound()
            exit(CLIOutput.Exit.cancelled)
        }
        interrupted = true
        onInterrupt?()
    }

    /// Runs `work` with Ctrl+C cancelling it rather than ending the process; the work's own
    /// exit code stands, a stop included.
    static func interruptible(_ work: @escaping @Sendable () async -> Int32) async -> Int32 {
        // Watched before the work starts; an interrupt before it has a task is kept.
        let started = Locked<(task: Task<Int32, Never>?, asked: Bool)>((nil, false))
        let interrupts = watchInterrupts {
            started.withLock {
                $0.asked = true
                $0.task?.cancel()
            }
        }
        defer { interrupts.stop() }
        let task = Task { await work() }
        let asked = started.withLock {
            $0.task = task
            return $0.asked
        }
        if asked { task.cancel() }
        return await task.value
    }

    #if os(Windows)
    /// A control handler runs on a thread of its own; returning true keeps the process.
    static let controlHandler: @convention(c) (DWORD) -> WindowsBool = { event in
        CLI.interrupt(forcing: event == DWORD(CTRL_C_EVENT) || event == DWORD(CTRL_BREAK_EVENT))
        return true
    }

    static func watchInterrupts(_ cancel: @escaping @Sendable () -> Void) -> InterruptWatch {
        onInterrupt = cancel
        SetConsoleCtrlHandler(controlHandler, true)
        return InterruptWatch()
    }
    #else
    static func watchInterrupts(_ cancel: @escaping @Sendable () -> Void) -> InterruptWatch {
        onInterrupt = cancel
        let watch = InterruptWatch()
        for (number, forcing) in [(SIGINT, true), (SIGTERM, false), (SIGHUP, false)] {
            let previous = signal(number, SIG_IGN)
            // One the caller set to be ignored stays so: `nohup` sets the hang-up aside.
            // SIG_IGN is 1 on every POSIX.
            guard previous.map({ unsafeBitCast($0, to: Int.self) }) != 1 else { continue }
            watch.restores.append { signal(number, previous) }
            let source = DispatchSource.makeSignalSource(signal: number, queue: .global())
            source.setEventHandler { CLI.interrupt(forcing: forcing) }
            source.resume()
            watch.sources.append(source)
        }
        return watch
    }
    #endif
}
