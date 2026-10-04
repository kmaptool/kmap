import Foundation

/// A decode buffer kept at its full size from block to block, with how much of it the
/// current element uses. Filled through a pointer, not by an `append` for every value.
struct ReusedBuffer<Element> {
    private(set) var storage: [Element] = []
    private(set) var count = 0
    private let zero: Element

    init(zero: Element) { self.zero = zero }

    mutating func removeAll() { count = 0 }

    /// What is in use, as the slice a sink is handed.
    var slice: ArraySlice<Element> { storage[0..<count] }

    /// Lets `body` write up to `most` more elements after those in use; it answers how
    /// many it wrote.
    @inline(__always)
    mutating func append(atMost most: Int, _ body: (UnsafeMutablePointer<Element>) -> Int) {
        guard most > 0 else { return }
        // 1 element more than asked for, so what is in use is never the whole storage:
        // `Array(slice)` over a whole buffer shares it, and a sink keeping one would
        // send the next refill to a fresh allocation.
        if storage.count <= count + most {
            storage.append(contentsOf: repeatElement(zero, count: count + most + 1 - storage.count))
        }
        let from = count
        count += storage.withUnsafeMutableBufferPointer { buffer -> Int in
            guard let base = buffer.baseAddress else { return 0 }
            return body(base + from)
        }
    }
}
