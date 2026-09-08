import Foundation

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
