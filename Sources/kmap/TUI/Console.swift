import Foundation

/// The platform-dependent part of the interface: raw mode, window size, byte output,
/// input waiting and reading, and interrupt notification. Escape sequences, key parsing
/// and drawing are portable and live above it.
protocol ConsoleBackend {

    /// Turns off line editing and echo, and asks for VT sequences in both directions.
    /// Returns false when there is no console, such as a pipe or a redirected stream.
    static func enterRawMode() -> Bool

    /// Puts back exactly what `enterRawMode` found.
    static func restore()

    /// Remembers the shape of the console before another program is given it.
    static func lend()

    /// Puts the console back into the mode `enterRawMode` asked for, and back to the shape
    /// `lend` remembered if it came back smaller. Takes nothing as the state to restore on
    /// exit: that is what `enterRawMode` found, and this is after another program has had
    /// the console and left it its own way.
    static func reclaim()

    /// The window, in cells. `(80, 24)` when there is nothing to ask.
    static func size() -> (columns: Int, rows: Int)

    /// Writes every byte, or as many as it can.
    static func write(_ bytes: [UInt8])

    /// Waits up to `milliseconds` for something to read.
    static func waitForInput(milliseconds: Int32) -> Readiness

    /// Reads what is waiting into `buffer`. Returns the byte count, 0 at end of input,
    /// or a negative number on error.
    static func read(into buffer: inout [UInt8]) -> Int

    /// Calls `handler` on ^C or a closing console.
    ///
    /// The handler runs in a signal-handler context: it may touch only what
    /// `Terminal.stop()` touches.
    static func onInterrupt(_ handler: @escaping () -> Void)
}

/// What a wait for input came back with.
enum Readiness {
    /// Something is there to read.
    case ready
    /// The time ran out. The frame is drawn anyway; this is the interface's clock.
    case nothingYet
    /// Input is at end and nothing further will arrive: a closed console or an exhausted
    /// pipe.
    case ended
}

#if os(Windows)
typealias Console = WindowsConsole
#else
typealias Console = POSIXConsole
#endif
