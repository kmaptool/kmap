#if !os(Windows)
import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// `ConsoleBackend` on Unix: termios raw mode, `poll` for input, and signal handlers.
enum POSIXConsole: ConsoleBackend {

    private static var original = termios()
    private static var rawEnabled = false

    static func enterRawMode() -> Bool {
        guard tcgetattr(STDIN_FILENO, &original) == 0 else { return false }
        applyRaw()
        rawEnabled = true
        return true
    }

    /// Nothing to remember: a helper here talks to a display server, not to this terminal.
    static func lend() {}

    static func reclaim() {
        guard rawEnabled else { return }
        applyRaw()
    }

    private static func applyRaw() {
        var raw = original
        raw.c_lflag &= ~(tcflag_t(ECHO) | tcflag_t(ICANON) | tcflag_t(ISIG) | tcflag_t(IEXTEN))
        raw.c_iflag &= ~(tcflag_t(IXON) | tcflag_t(ICRNL) | tcflag_t(BRKINT) | tcflag_t(INPCK) | tcflag_t(ISTRIP))
        raw.c_oflag &= ~tcflag_t(OPOST)
        raw.c_cflag |= tcflag_t(CS8)
        withUnsafeMutablePointer(to: &raw.c_cc) { ptr in
            ptr.withMemoryRebound(to: cc_t.self, capacity: Int(NCCS)) { cc in
                cc[Int(VMIN)] = 0   // non-blocking-ish read
                cc[Int(VTIME)] = 1  // 100ms poll timeout
            }
        }
        tcsetattr(STDIN_FILENO, TCSAFLUSH, &raw)
    }

    static func restore() {
        guard rawEnabled else { return }
        tcsetattr(STDIN_FILENO, TCSAFLUSH, &original)
        rawEnabled = false
    }

    static func size() -> (columns: Int, rows: Int) {
        var ws = winsize()
        if ioctl(STDOUT_FILENO, UInt(TIOCGWINSZ), &ws) == 0, ws.ws_col > 0 {
            return (Int(ws.ws_col), Int(ws.ws_row))
        }
        return (80, 24)
    }

    static func write(_ bytes: [UInt8]) {
        bytes.withUnsafeBytes { ptr in
            guard let base = ptr.baseAddress else { return }
            var written = 0
            while written < ptr.count {
                let n = Glibcish.write(STDOUT_FILENO, base.advanced(by: written),
                                       ptr.count - written)
                if n > 0 { written += n; continue }
                // A frame is resent only when it changes, so a partial write is never
                // repaired later: EINTR and EAGAIN must be retried, not abandoned.
                if errno == EINTR { continue }
                if errno == EAGAIN || errno == EWOULDBLOCK {
                    var pfd = pollfd(fd: STDOUT_FILENO, events: Int16(POLLOUT), revents: 0)
                    _ = poll(&pfd, 1, 100)
                    continue
                }
                break
            }
        }
    }

    /// Waits with `poll` rather than relying on the driver's `VTIME`, which some drivers
    /// ignore and block until a key arrives.
    static func waitForInput(milliseconds: Int32) -> Readiness {
        var descriptor = pollfd(fd: STDIN_FILENO, events: Int16(POLLIN), revents: 0)
        guard poll(&descriptor, 1, milliseconds) > 0 else { return .nothingYet }
        if descriptor.revents & Int16(POLLHUP | POLLERR | POLLNVAL) != 0 { return .ended }
        return descriptor.revents & Int16(POLLIN) != 0 ? .ready : .nothingYet
    }

    static func read(into buffer: inout [UInt8]) -> Int {
        Glibcish.read(STDIN_FILENO, &buffer, buffer.count)
    }

    static func onInterrupt(_ handler: @escaping () -> Void) {
        interrupted = handler
        let leaving: @convention(c) (Int32) -> Void = { _ in
            POSIXConsole.interrupted?()
            _exit(0)
        }
        signal(SIGINT, leaving)
        signal(SIGTERM, leaving)
        signal(SIGHUP, leaving)
        signal(SIGPIPE, SIG_IGN)
        // On a fatal signal the terminal is restored, then the signal is re-raised under
        // its default action so the crash is still reported.
        let crashing: @convention(c) (Int32) -> Void = { sig in
            POSIXConsole.interrupted?()
            signal(sig, SIG_DFL)
            raise(sig)
        }
        for sig in [SIGABRT, SIGILL, SIGTRAP, SIGSEGV, SIGBUS, SIGFPE] {
            // A signal already ignored stays ignored, SIGTRAP on WSL 1 (main.swift).
            // SIG_IGN is 1 on every POSIX.
            let previous = signal(sig, crashing)
            if previous.map({ unsafeBitCast($0, to: Int.self) }) == 1 { signal(sig, SIG_IGN) }
        }
    }

    /// Held here because a C function pointer cannot capture anything.
    private static var interrupted: (() -> Void)?
}

/// The C `read` and `write` under distinct names: unqualified calls in this file would
/// otherwise resolve to `Array.write` or `POSIXConsole.read`.
private enum Glibcish {
    static func write(_ fd: Int32, _ buffer: UnsafeRawPointer, _ count: Int) -> Int {
        #if canImport(Darwin)
        return Darwin.write(fd, buffer, count)
        #else
        return Glibc.write(fd, buffer, count)
        #endif
    }

    static func read(_ fd: Int32, _ buffer: UnsafeMutableRawPointer, _ count: Int) -> Int {
        #if canImport(Darwin)
        return Darwin.read(fd, buffer, count)
        #else
        return Glibc.read(fd, buffer, count)
        #endif
    }
}
#endif
