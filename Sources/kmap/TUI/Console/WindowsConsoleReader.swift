#if os(Windows)
import Foundation
import WinSDK

/// The thread behind `WindowsConsole` that does the blocking read, and the bytes it has
/// collected. A console handle has no `poll` equivalent, so the wait is on a condition
/// the thread signals.
extension WindowsConsole {
    final class Reader {
        /// Wide characters read from a console at a time.
        private static let consoleChunk = 1024
        /// Bytes read from a pipe or a redirect at a time.
        private static let pipeChunk = 4096
        private static let stackSize = 64 * 1024

        private let condition = NSCondition()
        private var buffer: [UInt8] = []
        private var ended = false
        private var started = false

        func start() {
            condition.lock()
            defer { condition.unlock() }
            guard !started else { return }
            started = true
            let thread = Thread { [self] in loop() }
            thread.stackSize = Self.stackSize
            thread.start()
        }

        private func loop() {
            let handle = WindowsConsole.input
            // A console is read wide: the byte read hands back nothing for a key outside
            // the ANSI code page, which is every letter of a non-English layout. A pipe
            // or a redirect has no wide read and is already UTF-8.
            var console = false
            if let handle, handle != INVALID_HANDLE_VALUE {
                var mode: DWORD = 0
                console = GetConsoleMode(handle, &mode)
            }
            while true {
                guard let handle, handle != INVALID_HANDLE_VALUE else { break }
                guard let bytes = console ? readWide(handle) : readBytes(handle) else { break }
                // A key that carries no character, a bare Shift, reads as nothing.
                if bytes.isEmpty { continue }
                condition.lock()
                buffer.append(contentsOf: bytes)
                condition.signal()
                condition.unlock()
            }
            condition.lock()
            ended = true
            condition.signal()
            condition.unlock()
        }

        /// Reads UTF-16 from a console and returns it as UTF-8; nil once the input ends.
        private func readWide(_ handle: HANDLE) -> [UInt8]? {
            let capacity = Self.consoleChunk
            var chunk = [WCHAR](repeating: 0, count: capacity)
            var got: DWORD = 0
            let ok = chunk.withUnsafeMutableBytes {
                ReadConsoleW(handle, $0.baseAddress, DWORD(capacity), &got, nil)
            }
            guard ok else { return nil }
            return Array(String(decoding: chunk[0..<Int(got)], as: UTF16.self).utf8)
        }

        /// The same for a handle that is not a console.
        private func readBytes(_ handle: HANDLE) -> [UInt8]? {
            var chunk = [UInt8](repeating: 0, count: Self.pipeChunk)
            var got: DWORD = 0
            let ok = chunk.withUnsafeMutableBytes {
                ReadFile(handle, $0.baseAddress, DWORD($0.count), &got, nil)
            }
            guard ok, got > 0 else { return nil }
            return Array(chunk[0..<Int(got)])
        }

        func wait(milliseconds: Int32) -> Readiness {
            condition.lock()
            defer { condition.unlock() }
            if !buffer.isEmpty { return .ready }
            if ended { return .ended }
            // The answer is discarded: signalled or timed out, what decides the result is
            // the state below, read fresh under the same lock.
            _ = condition.wait(until: Date().addingTimeInterval(Double(milliseconds) / 1000))
            if !buffer.isEmpty { return .ready }
            return ended ? .ended : .nothingYet
        }

        func take(into destination: inout [UInt8]) -> Int {
            condition.lock()
            defer { condition.unlock() }
            if buffer.isEmpty { return ended ? 0 : -1 }
            let count = min(destination.count, buffer.count)
            for index in 0..<count { destination[index] = buffer[index] }
            buffer.removeFirst(count)
            return count
        }
    }
}
#endif
