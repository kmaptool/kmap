import CLibdeflate
import Foundation

/// Deflate and inflate of complete wrapped streams (2-byte header, body, adler32 tail),
/// which is what a PBF blob and a GeoTIFF tile hold, through libdeflate.
///
/// Whole buffers rather than streams: everything compressed here is in memory and
/// bounded. Calls on many threads are independent, each with working memory of its own.
enum Deflate {
    enum Failure: Error, LocalizedError, Equatable {
        /// libdeflate's own result code, for a stream that would not inflate.
        case corrupt(Int32)
        /// The stream inflated to a different size than declared.
        case unexpectedSize(expected: Int, got: Int)

        var errorDescription: String? {
            switch self {
            case .corrupt(let code): return "a compressed stream would not inflate (\(code))"
            case .unexpectedSize(let expected, let got):
                return "a stream claiming \(expected) bytes inflated to \(got)"
            }
        }
    }

    /// The result code of a stream that is not one, as `Failure.corrupt` carries it.
    static let badData = Int32(LIBDEFLATE_BAD_DATA.rawValue)

    /// libdeflate's working memory for 1 call at a time: a compressor or a decompressor.
    /// Kept and handed round, since making one costs more than a small block takes.
    /// `@unchecked Sendable` stands on that: a taken one is out of the pool until given back.
    private struct Worker: @unchecked Sendable {
        let pointer: OpaquePointer
    }

    private static let compressors = Locked<[Worker]>([])
    private static let decompressors = Locked<[Worker]>([])

    /// Inflates a complete stream into `out`, which must be large enough.
    ///
    /// - Returns: The number of bytes written.
    /// - Throws: `Failure.corrupt` with libdeflate's result code.
    @discardableResult
    static func inflate(
        _ input: UnsafeRawBufferPointer,
        into out: UnsafeMutableBufferPointer<UInt8>
    ) throws -> Int {
        guard let source = input.baseAddress, !input.isEmpty,
            let destination = out.baseAddress, !out.isEmpty
        else {
            throw Failure.corrupt(badData)
        }
        let taken =
            decompressors.withLock { $0.popLast() }
            ?? libdeflate_alloc_decompressor().map(Worker.init)
        guard let worker = taken else { throw Failure.corrupt(badData) }
        defer { decompressors.withLock { $0.append(worker) } }
        var written = 0
        let result = libdeflate_zlib_decompress(
            worker.pointer,
            source,
            input.count,
            destination,
            out.count,
            &written
        )
        guard result == LIBDEFLATE_SUCCESS else { throw Failure.corrupt(Int32(result.rawValue)) }
        return written
    }

    /// Inflates a complete stream and checks its inflated size.
    ///
    /// - Throws: `Failure.unexpectedSize` when the result is not `expecting` bytes, since
    ///   that size comes off the wire and is not trusted.
    static func inflate(
        _ input: UnsafeRawBufferPointer,
        into out: UnsafeMutableBufferPointer<UInt8>,
        expecting: Int
    ) throws {
        let written = try inflate(input, into: out)
        guard written == expecting else {
            throw Failure.unexpectedSize(expected: expecting, got: written)
        }
    }

    /// The deflate level, of libdeflate's 1 to 12. Measured on a split: level 2 writes
    /// the tiles 4% faster and 0.5% larger, level 9 16% slower and 0.2% smaller.
    static let level: Int32 = 5

    /// Deflates `payload` into a complete stream.
    ///
    /// - Returns: The stream, or nil where libdeflate declines; callers store the bytes
    ///   uncompressed instead.
    static func deflate(_ payload: UnsafeRawBufferPointer) -> [UInt8]? {
        guard let source = payload.baseAddress, !payload.isEmpty else { return nil }
        let taken =
            compressors.withLock { $0.popLast() }
            ?? libdeflate_alloc_compressor(level).map(Worker.init)
        guard let worker = taken else { return nil }
        defer { compressors.withLock { $0.append(worker) } }
        // libdeflate's own worst-case bound; a smaller buffer may not hold the stream.
        let bound = libdeflate_zlib_compress_bound(worker.pointer, payload.count)
        let out = [UInt8](unsafeUninitializedCapacity: bound) { buffer, filled in
            filled = libdeflate_zlib_compress(worker.pointer, source, payload.count, buffer.baseAddress, bound)
        }
        return out.isEmpty ? nil : out
    }

    static func deflate(_ payload: [UInt8]) -> [UInt8]? {
        payload.withUnsafeBytes { deflate($0) }
    }
}
