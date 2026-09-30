import Foundation

/// Shows a file in the desktop's file manager. Nothing happens where there is none.
enum Reveal {
    static func show(_ url: URL) {
        guard let command = Platform.revealCommand(for: url) else { return }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: command.executable)
        process.arguments = command.arguments
        try? process.run()
    }
}
