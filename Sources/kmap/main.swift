import Foundation

#if canImport(Glibc)
import Glibc
#elseif os(Windows)
import WinSDK
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
    // A tool a cancelled build asked to stop may not have yet; it is not left running.
    ChildProcess.leave()
} else {
    let status = await CLI.run(arguments)
    // The command's watch is over, so a second Ctrl+C, or the second hang-up a closed
    // terminal sends, would end kmap before its tools: they wait the 2 s out.
    #if os(Windows)
    SetConsoleCtrlHandler(nil, true)
    #else
    for number in [SIGINT, SIGTERM, SIGHUP] { signal(number, SIG_IGN) }
    #endif
    ChildProcess.leave()
    exit(status)
}
