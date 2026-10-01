import Foundation

/// The writer's pipeline. A batch is built and deflated on whichever core is free, and
/// appended to its file in the order it was handed over.
/// The compressing is shared between writers: a split has a writer per tile, and the
/// nodes of an extract arrive in long runs for 1 tile at a time.
extension PBFWriter {
    /// How many batches may be in flight across every writer at once, built or waiting
    /// their turn. Shared, so the memory held is bounded by the machine rather than by
    /// the number of writers open.
    static let room = DispatchSemaphore(value: pendingBatches)
    private static let pendingBatches = max(leastPending, Machine.cores)
    private static let leastPending = 8

    /// Where blocks are built and deflated, whichever writer they belong to.
    private static let compressors = DispatchQueue(
        label: "kmap.pbf.compress",
        qos: .userInitiated,
        attributes: .concurrent
    )

    /// Bytes gathered before writing to disk. Small, since a split keeps one writer open per
    /// tile and each holds this much.
    static let flushThreshold = 1 << 20

    /// Hands a batch over: `make` builds its blocks on another core, they are deflated
    /// there, and the result is appended when every batch before it has been. Waits while
    /// too many are in flight. Called from 1 thread a writer; the ticket is the order.
    func submit(_ make: @escaping () -> [Piece]) {
        Self.room.wait()
        let ticket = tickets.withLock { next -> Int in
            defer { next += 1 }
            return next
        }
        inFlight.enter()
        // Neither closure is shared, and `finish` waits for the group, so the writer
        // outlives them.
        nonisolated(unsafe) let make = make
        nonisolated(unsafe) let writer = self
        Self.compressors.async {
            let pieces = make()
            let bodies = pieces.map { piece -> [UInt8] in
                if case .toCompress(_, let payload) = piece { return Self.deflate(payload) }
                return []
            }
            let packed = Packed(pieces: pieces, bodies: bodies)
            writer.queue.async { writer.take(packed, ticket: ticket) }
        }
    }

    /// On the writer's queue: keeps a batch until its turn, then appends it and every
    /// one after it that is already here. A PBF's block order is significant.
    private func take(_ packed: Packed, ticket: Int) {
        ready[ticket] = packed
        while let next = ready.removeValue(forKey: appended) {
            append(next)
            appended += 1
            Self.room.signal()
            inFlight.leave()
        }
    }

    /// Copies a blob through untouched, header and all.
    func copy(header: UnsafeRawBufferPointer, blob: UnsafeRawBufferPointer) {
        // Copied here rather than on the queue: these point into a mapped file the caller is
        // still walking.
        let headerBytes = Array(header)
        let blobBytes = Array(blob)
        submit { [.copied(header: headerBytes, blob: blobBytes)] }
    }

    private func append(_ packed: Packed) {
        for (index, piece) in packed.pieces.enumerated() {
            switch piece {
            case .copied(let header, let blob):
                appendLength(header.count)
                buffer.append(contentsOf: header)
                buffer.append(contentsOf: blob)
            case .toCompress(let kind, let payload):
                var blob = ProtoWriter()
                if packed.bodies[index].isEmpty {
                    // Deflate may decline; the format allows a blob to carry raw bytes.
                    blob.bytesField(PBFSchema.blobRaw, payload)
                } else {
                    blob.varintField(PBFSchema.blobRawSize, Int64(payload.count))
                    blob.bytesField(PBFSchema.blobDeflated, packed.bodies[index])
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

    /// Once a write has failed the rest is dropped: the file is lost either way, and
    /// `finish` reports the first failure.
    private func flush() {
        guard !buffer.isEmpty else { return }
        defer { buffer.removeAll(keepingCapacity: true) }
        guard writeFailure == nil else { return }
        do {
            try handle.write(contentsOf: Data(buffer))
        } catch {
            writeFailure = error
        }
    }

    /// Finishes the file. Nothing may be written afterwards.
    /// - Throws: the first write that failed, or the close.
    func finish() throws {
        guard !finished else { return }
        finished = true
        // Every batch appended, then the tail written, so the file is complete on return.
        inFlight.wait()
        let failure = queue.sync { () -> Error? in
            flush()
            return writeFailure
        }
        if let failure {
            try? handle.close()
            throw failure
        }
        try handle.close()
    }

    /// Deflates as a PBF requires: 2-byte header, body and adler32 tail. Returns an empty
    /// array where the compressor declines; the caller then writes the bytes uncompressed.
    private static func deflate(_ payload: [UInt8]) -> [UInt8] {
        Deflate.deflate(payload) ?? []
    }
}
