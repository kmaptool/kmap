import Foundation

/// The readers that decode across every core: in file order with a double buffer, or one
/// sink per worker for order-independent work.
extension PBFReader {
    /// Decodes batches of blocks across every core, then calls `apply` once per block in
    /// file order. `apply` must empty the sink it is given: the same sinks are reused for
    /// the next batch.
    func readInOrder<Sink: OSMSink>(make: () -> Sink,
                                    apply: (inout Sink) throws -> Void) throws {
        let data = try Data(contentsOf: url, options: .alwaysMapped)
        let width = Machine.readers

        // Two halves used in turn: one is applied on this thread while the next decodes on
        // the others. Separate objects, so no one array is reached into by two threads.
        let halves = [Half(width: width, make: make), Half(width: width, make: make)]

        try data.withUnsafeBytes { file in
            var blobs: [UnsafeRawBufferPointer] = []
            try Self.forEachBlob(in: file) { _, kind, blob in
                guard kind == PBFSchema.dataBlob else { return }
                blobs.append(blob)
            }
            guard !blobs.isEmpty else { return }
            
            nonisolated(unsafe) let batch = blobs

            let group = DispatchGroup()
            let pool = DispatchQueue.global(qos: .userInitiated)

            /// Decodes one batch of blobs into one half's slots.
            func decode(_ range: Range<Int>, into half: Half<Sink>) {
                group.enter()
                pool.async {
                    half.sinks.withUnsafeMutableBufferPointer { targets in
                        half.scratches.withUnsafeMutableBufferPointer { buffers in
                            half.failures.withUnsafeMutableBufferPointer { errors in
                            half.fieldSets.withUnsafeMutableBufferPointer { fields in
                                nonisolated(unsafe) let targets = targets
                                nonisolated(unsafe) let buffers = buffers
                                nonisolated(unsafe) let errors = errors
                                nonisolated(unsafe) let fields = fields
                                DispatchQueue.concurrentPerform(iterations: range.count) { i in
                                    do {
                                        let size = try Self.inflate(batch[range.lowerBound + i],
                                                                    into: &buffers[i])
                                        try buffers[i].withUnsafeBytes { payload in
                                            try Self.decodeBlock(
                                                UnsafeRawBufferPointer(rebasing: payload[0..<size]),
                                                into: &targets[i], fields: &fields[i])
                                        }
                                    } catch {
                                        errors[i] = error
                                    }
                                }
                            }
                            }
                        }
                    }
                    group.leave()
                }
            }

            var batches: [Range<Int>] = []
            var at = 0
            while at < blobs.count {
                let end = min(at + width, blobs.count)
                batches.append(at..<end)
                at = end
            }

            if stopped() { throw CancellationError() }
            decode(batches[0], into: halves[0])
            for (index, batch) in batches.enumerated() {
                group.wait()
                // Nothing is in flight here: the next batch is dispatched below.
                if stopped() { throw CancellationError() }
                let half = halves[index % halves.count]
                if index + 1 < batches.count {
                    decode(batches[index + 1], into: halves[(index + 1) % halves.count])
                }
                for i in 0..<batch.count {
                    if let failure = half.failures[i] {
                        half.failures = [Error?](repeating: nil, count: width)
                        group.wait()
                        throw failure
                    }
                    try apply(&half.sinks[i])
                }
            }
            group.wait()
        }
    }

    /// One half of the in-order reader's double buffer: the sinks a batch decodes into and
    /// the buffers it decodes with. One slot is touched by one worker at a time and one
    /// half by one thread at a time, so the arrays need no lock. The buffers are kept for
    /// the whole file rather than made per block.
    private final class Half<Sink: OSMSink> {
        var sinks: [Sink]
        var scratches: [[UInt8]]
        var failures: [Error?]
        var fieldSets: [Scratch]

        init(width: Int, make: () -> Sink) {
            sinks = (0..<width).map { _ in make() }
            scratches = [[UInt8]](repeating: [], count: width)
            failures = [Error?](repeating: nil, count: width)
            fieldSets = (0..<width).map { _ in Scratch() }
        }
    }

    /// Reads the file with one sink per worker and returns them for the caller to combine.
    /// Only for order-independent work: each worker takes a contiguous run of blocks, so
    /// merging the sinks in worker order reproduces the file's own order.
    func readConcurrently<Sink: OSMSink>(workers: Int = 0,
                                         make: () -> Sink) throws -> [Sink] {
        let data = try Data(contentsOf: url, options: .alwaysMapped)
        let width = workers > 0 ? workers
            : Machine.readers

        var sinks = (0..<width).map { _ in make() }
        var failures = [Error?](repeating: nil, count: width)
        try data.withUnsafeBytes { file in
            var blobs: [UnsafeRawBufferPointer] = []
            try Self.forEachBlob(in: file) { _, kind, blob in
                guard kind == PBFSchema.dataBlob else { return }
                blobs.append(blob)
            }
            guard !blobs.isEmpty else { return }
            if stopped() { throw CancellationError() }
            let share = (blobs.count + width - 1) / width

            try sinks.withUnsafeMutableBufferPointer { targets in
                try Self.acrossCores(width, failures: &failures) { worker in
                    let from = worker * share
                    let to = min(from + share, blobs.count)
                    guard from < to else { return }
                    var scratch = [UInt8]()
                    var fields = Scratch()
                    for index in from..<to {
                        if shouldStop() { throw CancellationError() }
                        let size = try Self.inflate(blobs[index], into: &scratch)
                        try scratch.withUnsafeBytes { payload in
                            try Self.decodeBlock(
                                UnsafeRawBufferPointer(rebasing: payload[0..<size]),
                                into: &targets[worker], fields: &fields)
                        }
                    }
                }
            }
        }
        return sinks
    }
}
