import Foundation

#if canImport(Glibc)
import Glibc
#endif

#if !os(Windows)
// A reader that closes the pipe early, as `| head` does, fails the write and not the run:
// a build stopped by the signal would leave its tools running.
signal(SIGPIPE, SIG_IGN)
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
