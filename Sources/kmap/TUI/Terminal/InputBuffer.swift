import Foundation

/// Bytes from the console, held ahead of the decoder. A read stops at a fixed size, so a
/// held arrow, three bytes a repeat, is cut in two every so often; the buffer tops itself
/// up on request so the tail of a sequence is not decoded as a key of its own.
struct InputBuffer {
    /// Bytes asked for in one read.
    static let readSize = 64

    private let source: InputSource
    private var pending: [UInt8] = []

    /// Whether standard input has ended: hung up, or read back nothing. Observed from
    /// reads rather than predicted with `isatty`, which can be wrong before a console is
    /// attached.
    private(set) var hasEnded = false

    init(reading source: InputSource) {
        self.source = source
    }

    var isEmpty: Bool { pending.isEmpty }
    var count: Int { pending.count }
    var first: UInt8? { pending.first }

    /// The next byte, taken out of the buffer.
    mutating func popFirst() -> UInt8? {
        pending.isEmpty ? nil : pending.removeFirst()
    }

    /// Everything buffered, taken out.
    mutating func drain() -> [UInt8] {
        defer { pending.removeAll() }
        return pending
    }

    mutating func replace(with bytes: [UInt8]) { pending = bytes }

    mutating func removeAll() { pending.removeAll() }

    /// Whether something is there to read, waiting up to `milliseconds` for it.
    mutating func isReady(within milliseconds: Int32) -> Bool {
        switch source.wait(milliseconds: milliseconds) {
        case .ready: return true
        case .nothingYet: return false
        case .ended:
            hasEnded = true
            return false
        }
    }

    /// One read, once something is there. False when nothing came within the wait.
    @discardableResult
    mutating func fill(within milliseconds: Int32, size: Int = readSize) -> Bool {
        guard isReady(within: milliseconds) else { return false }
        var chunk = [UInt8](repeating: 0, count: size)
        let n = source.read(into: &chunk)
        // Zero is end of file, which `poll` reports as readable.
        if n == 0 { hasEnded = true }
        guard n > 0 else { return false }
        pending.append(contentsOf: chunk[0..<n])
        return true
    }

    /// Tops the buffer up to `count` bytes, waiting `milliseconds` for each read.
    @discardableResult
    mutating func ensure(_ count: Int, within milliseconds: Int32) -> Bool {
        while pending.count < count {
            guard fill(within: milliseconds) else { return false }
        }
        return true
    }
}
