import Foundation

/// Shows a file in the desktop's file manager. Nothing happens where there is none.
enum Reveal {
    static func show(_ url: URL) {
        guard let command = Platform.revealCommand(for: url) else { return }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: command.executable)
        process.arguments = command.arguments
        // Not the raw-mode terminal: a file manager reading it would take kmap's keys.
        process.standardInput = ChildProcess.emptyInput
        process.standardOutput = ChildProcess.discardedOutput
        process.standardError = ChildProcess.discardedOutput
        try? process.run()
    }
}
