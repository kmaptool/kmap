import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif os(Windows)
import WinSDK
import ucrt
#endif

/// The two things about running a child that Foundation does not answer the same way on
/// every platform: how to insist that it stop, and how to read what is waiting in a pipe
/// without blocking for more. The rest of `Process` is portable.
enum ChildProcess {

    /// Stop it, having already asked politely.
    ///
    /// `Process.terminate()` sends SIGTERM on the Unixes, which a program may handle or
    /// ignore; SIGKILL it cannot. On Windows `terminate()` is already `TerminateProcess`,
    /// which is not refusable, and there are no signals.
    static func insist(on process: Process) {
        #if os(Windows)
        if process.isRunning { process.terminate() }
        #else
        if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        #endif
    }

    /// Somewhere for a child's standard input to come from, with nothing in it, so a tool
    /// that asks a question meets an immediate end of input rather than the raw-mode terminal.
    ///
    /// `FileHandle.nullDevice` is wrong on Windows: Foundation answers reads and writes
    /// itself, so a grandchild inherits no real handle. `NUL` is the actual device.
    static var emptyInput: FileHandle {
        #if os(Windows)
        return FileHandle(forReadingAtPath: "NUL") ?? FileHandle.nullDevice
        #else
        return FileHandle.nullDevice
        #endif
    }

    /// Somewhere for a child's output to go when nothing is reading it, for the same reason.
    static var discardedOutput: FileHandle {
        #if os(Windows)
        return FileHandle(forWritingAtPath: "NUL") ?? FileHandle.nullDevice
        #else
        return FileHandle.nullDevice
        #endif
    }

    /// Whatever is sitting in the pipe right now, without waiting for more.
    ///
    /// A pipe stays open as long as anything holds its writing end, including a grandchild
    /// the child left behind, so reading to end of file can block indefinitely. Both
    /// platforms read only what is available: POSIX by `O_NONBLOCK`, Windows by
    /// `PeekNamedPipe`, there being no non-blocking mode for a pipe there.
    static func readWhatIsWaiting(_ handle: FileHandle,
                                  into ingest: (String) -> Void) {
        #if os(Windows)
        let pipe = handle._handle
        guard pipe != INVALID_HANDLE_VALUE else { return }
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            var waiting: DWORD = 0
            guard PeekNamedPipe(pipe, nil, 0, nil, &waiting, nil), waiting > 0 else { return }
            var read: DWORD = 0
            let wanted = DWORD(min(Int(waiting), buffer.count))
            let ok = buffer.withUnsafeMutableBytes {
                ReadFile(pipe, $0.baseAddress, wanted, &read, nil)
            }
            guard ok, read > 0 else { return }
            ingest(String(decoding: buffer[0..<Int(read)], as: UTF8.self))
        }
        #else
        let descriptor = handle.fileDescriptor
        let flags = fcntl(descriptor, F_GETFL, 0)
        guard flags != -1, fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) != -1 else { return }
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let count = buffer.withUnsafeMutableBytes { raw in
                read(descriptor, raw.baseAddress, raw.count)
            }
            guard count > 0 else { return }   // 0 is end of file, -1 is "nothing waiting"
            ingest(String(decoding: buffer[0..<count], as: UTF8.self))
        }
        #endif
    }
}
