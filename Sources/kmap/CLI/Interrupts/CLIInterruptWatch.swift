import Foundation

#if os(Windows)
import WinSDK
#endif

extension CLI {
    /// The watch, held for as long as the build runs.
    final class InterruptWatch {
        #if !os(Windows)
        var sources: [DispatchSourceSignal] = []
        /// Puts each signal's own handling back once the watch is over.
        var restores: [() -> Void] = []
        #endif

        func stop() {
            #if os(Windows)
            SetConsoleCtrlHandler(CLI.controlHandler, false)
            #else
            for source in sources { source.cancel() }
            for restore in restores { restore() }
            #endif
        }
    }
}
