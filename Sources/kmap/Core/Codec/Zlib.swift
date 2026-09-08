import CZlib
import Foundation

/// Deflate and inflate of complete zlib streams — two-byte header, body, adler32 tail —
/// through the system's zlib.
///
/// Whole buffers rather than streams: everything compressed here is in memory and
/// bounded. `compress2` and `uncompress` hold no shared state, so calls on many threads
/// are independent.
enum Zlib {

    enum Failure: Error, LocalizedError, Equatable {
        /// zlib's own return code, for a stream that would not inflate.
        case corrupt(Int32)
        /// The stream inflated to a different size than declared.
        case unexpectedSize(expected: Int, got: Int)

        var errorDescription: String? {
            switch self {
            case .corrupt(let code): return "zlib refused a stream (\(code))"
            case .unexpectedSize(let expected, let got):
                return "a stream claiming \(expected) bytes inflated to \(got)"
            }
        }
    }

    /// Inflates a complete zlib stream into `out`, which must be large enough.
    ///
    /// - Returns: The number of bytes written.
    /// - Throws: `Failure.corrupt` with zlib's return code.
    @discardableResult
    static func inflate(_ input: UnsafeRawBufferPointer,
                        into out: UnsafeMutableBufferPointer<UInt8>) throws -> Int {
        guard let source = input.baseAddress, !input.isEmpty,
              let destination = out.baseAddress, !out.isEmpty else {
            throw Failure.corrupt(Z_DATA_ERROR)
        }
        var written = uLongf(out.count)
        let code = uncompress(destination, &written,
                              source.assumingMemoryBound(to: Bytef.self),
                              uLong(input.count))
        guard code == Z_OK else { throw Failure.corrupt(code) }
        return Int(written)
    }

    /// Inflates a complete zlib stream and checks its inflated size.
    ///
    /// - Throws: `Failure.unexpectedSize` when the result is not `expecting` bytes, since
    ///   that size comes off the wire and is not trusted.
    static func inflate(_ input: UnsafeRawBufferPointer,
                        into out: UnsafeMutableBufferPointer<UInt8>,
                        expecting: Int) throws {
        let written = try inflate(input, into: out)
        guard written == expecting else {
            throw Failure.unexpectedSize(expected: expecting, got: written)
        }
    }

    /// The deflate level. 5 rather than zlib's default 6, which is about a quarter
    /// slower here for two parts in a thousand of size.
    static let level: Int32 = 5

    /// Deflates `payload` into a complete zlib stream.
    ///
    /// - Returns: The stream, or nil where zlib declines; callers store the bytes
    ///   uncompressed instead.
    static func deflate(_ payload: UnsafeRawBufferPointer,
                        level: Int32 = Zlib.level) -> [UInt8]? {
        guard let source = payload.baseAddress, !payload.isEmpty else { return nil }
        // zlib's own worst-case bound; undersizing it truncates the stream.
        var capacity = compressBound(uLong(payload.count))
        var out = [UInt8](repeating: 0, count: Int(capacity))
        let code = out.withUnsafeMutableBufferPointer { buffer -> Int32 in
            guard let destination = buffer.baseAddress else { return Z_BUF_ERROR }
            return compress2(destination, &capacity,
                             source.assumingMemoryBound(to: Bytef.self),
                             uLong(payload.count), level)
        }
        guard code == Z_OK else { return nil }
        out.removeLast(out.count - Int(capacity))
        return out
    }

    static func deflate(_ payload: [UInt8], level: Int32 = Zlib.level) -> [UInt8]? {
        payload.withUnsafeBytes { deflate($0, level: level) }
    }
}
