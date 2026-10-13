import Foundation

extension CoarseEvidence {
    /// Buffers 1 core reuses from element to element, emptied but kept, so a pass
    /// allocates them once per core rather than once per element.
    struct Scratch {
        var seen = Set<UInt64>()
        var corners: [UInt64] = []
        var held: [Int32: Int] = [:]
    }
}
