import Foundation

#if os(Windows)
import WinSDK
#endif

/// Ctrl+C and a polite kill, routed to the running pipeline rather than the default
/// action, so child processes are stopped and the output stream ends with its last event.
/// A second Ctrl+C leaves at once, as a shell user expects when a cancellation hangs.
extension CLI {
    /// What an interrupt does: the first cancels, the next one exits.
    nonisolated(unsafe) private static var onInterrupt: (@Sendable () -> Void)?
    nonisolated(unsafe) private static var interrupted = false

    private static func interrupt() {
        if interrupted {
            // `exit` skips the defer that puts the console's code page back.
            ConsoleCodePage.restoreFound()
            exit(CLIOutput.Exit.cancelled)
        }
        interrupted = true
        onInterrupt?()
    }

    /// Runs `work` with Ctrl+C cancelling it rather than ending the process, so what it
    /// clears up on the way out is cleared.
    static func interruptible(_ work: @escaping @Sendable () async -> Int32) async -> Int32 {
        let task = Task { await work() }
        let stopped = Locked(false)
        let interrupts = watchInterrupts {
            stopped.withLock { $0 = true }
            task.cancel()
        }
        defer { interrupts.stop() }
        let code = await task.value
        return stopped.withLock { $0 } ? CLIOutput.Exit.cancelled : code
    }

    /// The watch, held for as long as the build runs.
    final class InterruptWatch {
        #if !os(Windows)
        fileprivate var sources: [DispatchSourceSignal] = []
        #endif

        func stop() {
            #if os(Windows)
            SetConsoleCtrlHandler(CLI.controlHandler, false)
            #else
            for source in sources { source.cancel() }
            #endif
        }
    }

    #if os(Windows)
    /// A control handler runs on a thread of its own; returning true keeps the process.
    private static let controlHandler: @convention(c) (DWORD) -> WindowsBool = { _ in
        CLI.interrupt()
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
        watch.sources = [SIGINT, SIGTERM].map { number in
            signal(number, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: number, queue: .global())
            source.setEventHandler { CLI.interrupt() }
            source.resume()
            return source
        }
        return watch
    }
    #endif
}
