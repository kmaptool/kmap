import Foundation

/// The writer's pipeline: blocks are deflated a batch at a time across every core and
/// appended in the order handed over, streamed to the file rather than held whole.
extension PBFWriter {
    /// How many batches may await writing across every writer at once. Shared, so the memory
    /// held is bounded by the machine rather than by the number of writers open.
    static let room = DispatchSemaphore(value: pendingBatches)
    private static let pendingBatches = 8

    /// Writers currently open. A lone writer compresses its batch across every core; with
    /// several open, each keeps to its own queue.
    static let live = LiveCount()

    /// `value` is reached only under `lock`, which is what `@unchecked Sendable` stands on.
    final class LiveCount: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0
        func enter() { lock.lock(); value += 1; lock.unlock() }
        func leave() { lock.lock(); value -= 1; lock.unlock() }
        var count: Int { lock.lock(); defer { lock.unlock() }; return value }
    }

    /// How many blocks are compressed in one go: one per core.
    private static let compressionBatch = max(leastBatch, Machine.cores)
    private static let leastBatch = 2

    /// Bytes gathered before writing to disk. Small, since a split keeps one writer open per
    /// tile and each holds this much.
    static let flushThreshold = 1 << 20

    /// Hands a batch to this writer's own queue, waiting if one is already there.
    func submit(_ work: @escaping () -> Void) {
        Self.room.wait()
        // Run once, on this writer's own serial queue, after the caller has let go of it.
        nonisolated(unsafe) let work = work
        queue.async {
            work()
            Self.room.signal()
        }
    }

    /// Copies a blob through untouched, header and all.
    func copy(header: UnsafeRawBufferPointer, blob: UnsafeRawBufferPointer) {
        // Copied here rather than on the queue: these point into a mapped file the caller is
        // still walking.
        let headerBytes = Array(header)
        let blobBytes = Array(blob)
        submit { [self] in enqueue(.copied(header: headerBytes, blob: blobBytes)) }
    }

    // MARK: Compressing a batch at a time

    func enqueue(_ piece: Piece) {
        pending.append(piece)
        // Batching pays only where the batch is compressed across the cores, which needs
        // this to be the only writer open.
        let batch = Self.live.count > 1 ? 1 : Self.compressionBatch
        if pending.count >= batch { drain() }
    }

    /// Compresses everything waiting, across every core, and appends the results in the
    /// order they were handed over; a PBF's block order is significant.
    private func drain() {
        guard !pending.isEmpty else { return }
        let work = pending
        pending.removeAll(keepingCapacity: true)

        var packed = [[UInt8]](repeating: [], count: work.count)
        if work.count == 1 || Self.live.count > 1 {
            for (index, piece) in work.enumerated() {
                if case .toCompress(_, let payload) = piece {
                    packed[index] = Self.deflate(payload)
                }
            }
        } else {
            packed.withUnsafeMutableBufferPointer { slots in
                // Each lane writes only its own slot, which no type can say: nothing is shared.
                nonisolated(unsafe) let slots = slots
                DispatchQueue.concurrentPerform(iterations: work.count) { i in
                    if case .toCompress(_, let payload) = work[i] {
                        slots[i] = Self.deflate(payload)
                    }
                }
            }
        }

        for (index, piece) in work.enumerated() {
            switch piece {
            case .copied(let header, let blob):
                appendLength(header.count)
                buffer.append(contentsOf: header)
                buffer.append(contentsOf: blob)
            case .toCompress(let kind, let payload):
                var blob = ProtoWriter()
                if packed[index].isEmpty {
                    // Deflate may decline; the format allows a blob to carry raw bytes.
                    blob.bytesField(PBFSchema.blobRaw, payload)
                } else {
                    blob.varintField(PBFSchema.blobRawSize, Int64(payload.count))
                    blob.bytesField(PBFSchema.blobZlib, packed[index])
                }
                var header = ProtoWriter()
                header.stringField(PBFSchema.blobHeaderKind, kind)
                header.varintField(PBFSchema.blobHeaderSize, Int64(blob.bytes.count))
                appendLength(header.bytes.count)
                buffer.append(contentsOf: header.bytes)
                buffer.append(contentsOf: blob.bytes)
            }
        }
        if buffer.count >= Self.flushThreshold { flush() }
    }

    private func appendLength(_ length: Int) {
        var big = UInt32(length).bigEndian
        withUnsafeBytes(of: &big) { buffer.append(contentsOf: $0) }
    }

    private func flush() {
        guard !buffer.isEmpty else { return }
        handle.write(Data(buffer))
        buffer.removeAll(keepingCapacity: true)
    }

    /// Finishes the file. Nothing may be written afterwards.
    func finish() throws {
        guard !finished else { return }
        finished = true
        // Drained synchronously, so the file is complete on return.
        queue.sync {
            drain()
            flush()
        }
        Self.live.leave()
        try handle.close()
    }

    /// Deflates as a PBF requires: zlib header, body and adler32 tail. Returns an empty
    /// array where zlib declines; the caller then writes the bytes uncompressed.
    private static func deflate(_ payload: [UInt8]) -> [UInt8] {
        Zlib.deflate(payload) ?? []
    }
}
