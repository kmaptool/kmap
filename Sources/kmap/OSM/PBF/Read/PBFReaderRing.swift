import Foundation

extension PBFReader {
    /// The in-order reader's slots and the workers filling them: block `i` decodes into
    /// slot `i % slots`, once the block before it in that slot has been applied. A slot is
    /// touched by 1 thread at a time, so the storage needs no lock. Raw storage keeps the
    /// workers off shared array reference counts.
    final class Ring<Sink: OSMSink>: @unchecked Sendable {
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
