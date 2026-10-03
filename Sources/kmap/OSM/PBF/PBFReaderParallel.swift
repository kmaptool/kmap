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
        var failures = [Error?](repeating: nil, count: sinks.count)
        try sinks.withUnsafeMutableBufferPointer { targets in
            try Self.acrossCores(targets.count, failures: &failures) { worker in
                var scratch = [UInt8]()
                var fields = Scratch()
                while case let index = claimed.takeNext(), index < blobs.count {
                    if shouldStop() { throw CancellationError() }
                    let held = try Self.decode(blobs[index], into: &targets[worker], scratch: &scratch, fields: &fields)
                    log?.note(index, holds: held)
                }
            }
        }
    }

    /// The in-order reader's slots and the workers filling them: block `i` decodes into
    /// slot `i % slots`, once the block before it in that slot has been applied. A slot is
    /// touched by 1 thread at a time, so the storage needs no lock. Raw storage keeps the
    /// workers off shared array reference counts.
    private final class Ring<Sink: OSMSink>: @unchecked Sendable {
        let slots: Int
        let sinks: UnsafeMutablePointer<Sink>
        private let scratches: UnsafeMutablePointer<[UInt8]>
        private let fieldSets: UnsafeMutablePointer<Scratch>
        private let failures: UnsafeMutablePointer<Error?>
        /// Signalled when a slot's block is decoded.
        private let ready: [DispatchSemaphore]
        /// 1 count per block claimed and not yet applied: a block is claimed only after a
        /// wait here, so block `i` is claimed once block `i - slots`, the last one in its
        /// slot, has been applied.
        private let room: DispatchSemaphore
        private let claimed = Locked(0)
        private let quit = Locked(false)
        private let running = DispatchGroup()

        init(slots: Int, make: () -> Sink) {
            self.slots = slots
            sinks = .allocate(capacity: slots)
            scratches = .allocate(capacity: slots)
            fieldSets = .allocate(capacity: slots)
            failures = .allocate(capacity: slots)
            for slot in 0..<slots {
                (sinks + slot).initialize(to: make())
                (scratches + slot).initialize(to: [])
                (fieldSets + slot).initialize(to: Scratch())
                (failures + slot).initialize(to: nil)
            }
            ready = (0..<slots).map { _ in DispatchSemaphore(value: 0) }
            room = DispatchSemaphore(value: slots)
        }

        deinit {
            sinks.deinitialize(count: slots).deallocate()
            scratches.deinitialize(count: slots).deallocate()
            fieldSets.deinitialize(count: slots).deallocate()
            failures.deinitialize(count: slots).deallocate()
        }

        /// Decodes `blobs` on `workers` threads and hands each block's slot to `apply`, in
        /// file order, on this thread.
        func decode(
            _ blobs: [UnsafeRawBufferPointer],
            workers: Int,
            log: BlobParts.Log?,
            apply: (Int) throws -> Void
        ) throws {
            start(blobs, workers: workers, log: log)
            // The workers read the mapped file: a throw below must stop them first.
            defer { stop(workers: workers) }
            for index in 0..<blobs.count {
                let slot = index % slots
                ready[slot].wait()
                if let failure = failures[slot] { throw failure }
                try apply(slot)
                room.signal()
            }
        }

        /// Workers take the next blob as each finishes and run up to `slots` blocks ahead
        /// of the applying thread, so no block waits for a slower neighbour. Threads of
        /// their own: held for the whole file, they would keep the dispatch pool from the
        /// work `apply` hands on, such as a writer's compressing.
        private func start(_ blobs: [UnsafeRawBufferPointer], workers: Int, log: BlobParts.Log?) {
            nonisolated(unsafe) let blobs = blobs
            for _ in 0..<workers {
                running.enter()
                let worker = Thread { [self] in
                    while let index = claim(below: blobs.count) {
                        fill(index % slots, from: blobs[index], blob: index, log: log)
                    }
                    running.leave()
                }
                worker.qualityOfService = .userInitiated
                worker.start()
            }
        }

        /// The next blob to decode, once its slot is free; nil when there is none or the
        /// read is over.
        private func claim(below count: Int) -> Int? {
            room.wait()
            if quit.withLock({ $0 }) { return nil }
            let index = claimed.takeNext()
            guard index < count else {
                room.signal()
                return nil
            }
            return index
        }

        private func fill(_ slot: Int, from blob: UnsafeRawBufferPointer, blob index: Int, log: BlobParts.Log?) {
            do {
                let held = try PBFReader.decode(
                    blob,
                    into: &sinks[slot],
                    scratch: &scratches[slot],
                    fields: &fieldSets[slot]
                )
                log?.note(index, holds: held)
            } catch {
                failures[slot] = error
            }
            ready[slot].signal()
        }

        /// Stops the workers and waits for them. The signals release every waiting worker
        /// and leave the semaphore no lower than it started, which libdispatch checks.
        private func stop(workers: Int) {
            quit.withLock { $0 = true }
            for _ in 0..<(slots + workers) { room.signal() }
            running.wait()
        }
    }
}
