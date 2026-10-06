import Foundation

#if os(Windows)
import WinSDK
#endif

extension CLI {
    /// The console's code page for the run: UTF-8, as the TUI sets it, or every dash and
    /// dot in the output is mojibake on a console at the OEM page. Put back on exit.
    struct ConsoleCodePage {
        #if os(Windows)
        private let input: UINT, output: UINT
        /// The pages found at the start, for an exit that does not unwind to the defer:
        /// a second Ctrl+C leaves through `exit`.
        nonisolated(unsafe) private static var found: ConsoleCodePage?

        static func utf8() -> ConsoleCodePage {
            let saved = ConsoleCodePage(input: GetConsoleCP(), output: GetConsoleOutputCP())
            found = saved
            SetConsoleCP(UINT(CP_UTF8))
            SetConsoleOutputCP(UINT(CP_UTF8))
            return saved
        }

        func restore() {
            SetConsoleCP(input)
            SetConsoleOutputCP(output)
        }

        static func restoreFound() { found?.restore() }
        #else
        static func utf8() -> ConsoleCodePage { ConsoleCodePage() }
        func restore() {}
        static func restoreFound() {}
        #endif
    }
}
