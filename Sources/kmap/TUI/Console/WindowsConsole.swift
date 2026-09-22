#if os(Windows)
import Foundation
import WinSDK

/// `ConsoleBackend` on Windows. VT processing is enabled in both directions so the shared
/// escape sequences and key parser apply unchanged; the console code pages are switched to
/// UTF-8 and restored on exit; and the blocking read runs on its own thread, since a
/// console handle has no `poll` equivalent.
enum WindowsConsole: ConsoleBackend {
    static let input: HANDLE? = GetStdHandle(STD_INPUT_HANDLE)
    private static let output: HANDLE? = GetStdHandle(STD_OUTPUT_HANDLE)

    private static var savedInputMode: DWORD?
    private static var savedOutputMode: DWORD?
    private static var savedInputCodePage: UINT?
    private static var savedOutputCodePage: UINT?

    /// The thread that does the blocking read, and the bytes it has collected.
    private static let reader = Reader()

    // MARK: Raw mode

    static func enterRawMode() -> Bool {
        guard let input, let output,
            input != INVALID_HANDLE_VALUE, output != INVALID_HANDLE_VALUE
        else { return false }
        var inputMode: DWORD = 0, outputMode: DWORD = 0
        // Fails when the handle is not a console, such as a pipe or a redirect.
        guard GetConsoleMode(input, &inputMode), GetConsoleMode(output, &outputMode) else {
            reader.start()
            return false
        }
        savedInputMode = inputMode
        savedOutputMode = outputMode
        savedInputCodePage = GetConsoleCP()
        savedOutputCodePage = GetConsoleOutputCP()

        applyModes()
        reader.start()
        return true
    }

    private static func applyModes() {
        SetConsoleCP(UINT(CP_UTF8))
        SetConsoleOutputCP(UINT(CP_UTF8))

        // Line editing, echo and the console's own ^C handling off; `ENABLE_MOUSE_INPUT`
        // off with `ENABLE_EXTENDED_FLAGS` on disables quick-edit mode, which would
        // otherwise consume clicks as text selection.
        if let input, let mode = savedInputMode {
            var raw = mode
            raw &= ~DWORD(
                ENABLE_ECHO_INPUT | ENABLE_LINE_INPUT | ENABLE_PROCESSED_INPUT
                    | ENABLE_MOUSE_INPUT | ENABLE_QUICK_EDIT_MODE | ENABLE_WINDOW_INPUT
            )
            raw |= DWORD(ENABLE_VIRTUAL_TERMINAL_INPUT | ENABLE_EXTENDED_FLAGS)
            SetConsoleMode(input, raw)
        }
        // Without DISABLE_NEWLINE_AUTO_RETURN the console wraps at the last column, so a
        // full-width line scrolls the screen.
        if let output, let mode = savedOutputMode {
            SetConsoleMode(
                output,
                mode | DWORD(ENABLE_VIRTUAL_TERMINAL_PROCESSING)
                    | DWORD(DISABLE_NEWLINE_AUTO_RETURN)
            )
        }
    }

    static func restore() {
        if let input, let mode = savedInputMode { SetConsoleMode(input, mode) }
        if let output, let mode = savedOutputMode { SetConsoleMode(output, mode) }
        if let page = savedInputCodePage { SetConsoleCP(page) }
        if let page = savedOutputCodePage { SetConsoleOutputCP(page) }
        savedInputMode = nil
        savedOutputMode = nil
        savedInputCodePage = nil
        savedOutputCodePage = nil
    }

    // MARK: Lending the console to a helper

    /// The console as it was handed over, so a helper that resizes it can be undone.
    private static var lentShape: CONSOLE_SCREEN_BUFFER_INFO?
    /// The font the console was lent with.
    private static var lentFont: CONSOLE_FONT_INFOEX?

    static func lend() {
        guard let output else { return }
        var info = CONSOLE_SCREEN_BUFFER_INFO()
        if GetConsoleScreenBufferInfo(output, &info) { lentShape = info }
        var font = CONSOLE_FONT_INFOEX()
        font.cbSize = DWORD(MemoryLayout<CONSOLE_FONT_INFOEX>.size)
        if GetCurrentConsoleFontEx(output, false, &font) { lentFont = font }
    }

    /// A program that shares this console leaves it its own way: the code page back to
    /// the machine's own, and every non-ASCII glyph drawn as something else.
    static func reclaim() {
        guard savedInputMode != nil else { return }
        applyModes()
        // The font first: it decides how many cells fit, so the shape is set against the
        // font that was lent, not the one that came back.
        restoreFont()
        restoreShape()
    }

    /// A code page change makes the console pick a font that can draw it, and a helper
    /// that changes the page leaves a different face behind, usually a raster one with no
    /// box drawing and a different size on screen.
    private static func restoreFont() {
        guard let output, var font = lentFont else { return }
        lentFont = nil
        font.cbSize = DWORD(MemoryLayout<CONSOLE_FONT_INFOEX>.size)
        SetCurrentConsoleFontEx(output, false, &font)
    }

    /// Puts the window back to the size it was lent at, when it came back smaller. A
    /// window the user made bigger meanwhile is left alone, and the buffer is only ever
    /// grown.
    private static func restoreShape() {
        guard let output, let want = lentShape else { return }
        lentShape = nil
        var now = CONSOLE_SCREEN_BUFFER_INFO()
        guard GetConsoleScreenBufferInfo(output, &now) else { return }
        guard
            now.srWindow.Bottom - now.srWindow.Top < want.srWindow.Bottom - want.srWindow.Top
                || now.srWindow.Right - now.srWindow.Left < want.srWindow.Right - want.srWindow.Left
        else { return }
        var size = want.dwSize
        size.X = max(size.X, now.dwSize.X)
        size.Y = max(size.Y, now.dwSize.Y)
        SetConsoleScreenBufferSize(output, size)
        var window = want.srWindow
        SetConsoleWindowInfo(output, true, &window)
    }

    // MARK: Size and output

    static func size() -> (columns: Int, rows: Int) {
        var info = CONSOLE_SCREEN_BUFFER_INFO()
        guard let output, GetConsoleScreenBufferInfo(output, &info) else { return fallbackSize }
        // The visible window, not the screen buffer, which is usually far taller.
        let columns = Int(info.srWindow.Right - info.srWindow.Left) + 1
        let rows = Int(info.srWindow.Bottom - info.srWindow.Top) + 1
        guard columns > 0, rows > 0 else { return fallbackSize }
        return (columns, rows)
    }

    static func write(_ bytes: [UInt8]) {
        guard let output else { return }
        bytes.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            var written = 0
            while written < raw.count {
                var wrote: DWORD = 0
                let ok = WriteFile(
                    output,
                    base.advanced(by: written),
                    DWORD(raw.count - written),
                    &wrote,
                    nil
                )
                if !ok || wrote == 0 { break }
                written += Int(wrote)
            }
        }
    }

    // MARK: Input

    static func waitForInput(milliseconds: Int32) -> Readiness {
        reader.wait(milliseconds: milliseconds)
    }

    static func read(into buffer: inout [UInt8]) -> Int {
        reader.take(into: &buffer)
    }

    // MARK: ^C

    static func onInterrupt(_ handler: @escaping () -> Void) {
        interrupted = handler
        // One handler for every control event: ^C, ^Break, close, logoff, shutdown. All
        // of them must restore the console out of raw mode and off the alternate screen.
        let trampoline: @convention(c) (DWORD) -> WindowsBool = { _ in
            WindowsConsole.interrupted?()
            ExitProcess(0)
        }
        SetConsoleCtrlHandler(trampoline, true)
    }

    /// Held here because a C function pointer cannot capture anything.
    private static var interrupted: (() -> Void)?
}
#endif
