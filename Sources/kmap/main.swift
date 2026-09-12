import Foundation
#if canImport(Glibc)
import Glibc
#endif

// WSL 1 misreports the futex wake libdispatch uses under dispatch_once, and libdispatch
// traps on the report. Ignored, the process runs on correctly; the price, on WSL 1 only,
// is that a genuine trap no longer stops it either.
#if os(Linux)
if Platform.isWSL1 { signal(SIGTRAP, SIG_IGN) }
#endif

Paths.bootstrap()

let arguments = Array(CommandLine.arguments.dropFirst())
if arguments.isEmpty {
    // No `isatty` check: under WSL the console may not be attached yet at startup.
    // A missing terminal is detected during the loop — see `Terminal.inputHasEnded`.
    await App().run()
} else {
    let status = await CLI.run(arguments)
    exit(status)
}
