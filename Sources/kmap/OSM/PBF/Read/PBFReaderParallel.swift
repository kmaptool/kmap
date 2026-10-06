import Foundation

/// The readers that decode across every core: in file order through a ring of slots, or
/// 1 sink per worker for order-independent work.
extension PBFReader {
    /// Slots in the in-order reader's ring per worker: how far the workers may run ahead
    /// of the thread applying the blocks.
    private static let slotsPerReader = 2

    /// Decodes blocks across every core, then calls `apply` once per block in file order.
    /// `apply` must empty the sink it is given: the same sinks are reused for later blocks.
    func readInOrder<Sink: OSMSink>(
        make: () -> Sink,
        apply: (inout Sink) throws -> Void
    ) throws {
        let data = try Data(contentsOf: url, options: .alwaysMapped)
        let width = Machine.readers
        try data.withUnsafeBytes { file in
            let all = try Self.dataBlobs(in: file)
            guard !all.isEmpty else { return }
            let ring = Ring(slots: Self.slotsPerReader * width, make: make)
            // Only the blobs holding something the sinks ask for, once the file is known.
            let (blobs, log) = BlobParts.select(all, of: url, wanted: ring.sinks[0].wantedParts)
            guard !blobs.isEmpty else { return }
            if stopped() { throw CancellationError() }
            try ring.decode(blobs, workers: min(width, blobs.count), log: log) { slot in
                if stopped() { throw CancellationError() }
                try apply(&ring.sinks[slot])
            }
            log?.keep()
        }
    }

    /// As `readInOrder`, over only the data blobs at `chosen`, numbered as a full pass numbers
    /// them: a second look at the few blobs a first pass found.
    func readInOrder<Sink: OSMSink>(
        blobs chosen: Set<Int>,
        make: () -> Sink,
        apply: (inout Sink) throws -> Void
    ) throws {
        guard !chosen.isEmpty else { return }
        let data = try Data(contentsOf: url, options: .alwaysMapped)
        let width = Machine.readers
        try data.withUnsafeBytes { file in
            let all = try Self.dataBlobs(in: file)
            let blobs = all.indices.filter(chosen.contains).map { all[$0] }
            guard !blobs.isEmpty else { return }
            let ring = Ring(slots: Self.slotsPerReader * width, make: make)
            if stopped() { throw CancellationError() }
            try ring.decode(blobs, workers: min(width, blobs.count), log: nil) { slot in
                if stopped() { throw CancellationError() }
                try apply(&ring.sinks[slot])
            }
        }
    }

    /// Reads the file with one sink per worker and returns them for the caller to combine.
    /// Only for order-independent work: a worker takes the next block whenever it is free,
    /// so no worker is left finishing a long share alone, and which blocks a sink holds
    /// differs from run to run.
    func readConcurrently<Sink: OSMSink>(
        workers: Int = 0,
        make: () -> Sink
    ) throws -> [Sink] {
        let data = try Data(contentsOf: url, options: .alwaysMapped)
        let width = workers > 0 ? workers : Machine.readers
        var sinks = (0..<width).map { _ in make() }
        try data.withUnsafeBytes { file in
            let all = try Self.dataBlobs(in: file)
            guard !all.isEmpty else { return }
            let (blobs, log) = BlobParts.select(all, of: url, wanted: sinks[0].wantedParts)
            guard !blobs.isEmpty else { return }
            if stopped() { throw CancellationError() }
            try decodeShared(blobs, into: &sinks, log: log)
            log?.keep()
        }
        return sinks
    }

    /// Every worker decodes into its own sink, taking the next blob as it is free.
    private func decodeShared<Sink: OSMSink>(
        _ blobs: [UnsafeRawBufferPointer],
        into sinks: inout [Sink],
        log: BlobParts.Log?
    ) throws {
        let claimed = Locked(0)
        // Set by a failing worker, so the rest stop at their next blob.
        let failed = Locked(false)
        var failures = [Error?](repeating: nil, count: sinks.count)
        try sinks.withUnsafeMutableBufferPointer { targets in
            try Self.acrossCores(targets.count, failures: &failures) { worker in
                var scratch = [UInt8]()
                var fields = Scratch()
                do {
                    while case let index = claimed.takeNext(), index < blobs.count, !failed.withLock({ $0 }) {
                        if shouldStop() { throw CancellationError() }
                        let held = try Self.decode(
                            blobs[index],
                            into: &targets[worker],
                            scratch: &scratch,
                            fields: &fields
                        )
                        log?.note(index, holds: held)
                    }
                } catch {
                    failed.withLock { $0 = true }
                    throw error
                }
            }
        }
    }
}
