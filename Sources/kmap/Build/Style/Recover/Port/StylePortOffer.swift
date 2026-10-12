import Foundation

extension StylePort {
    /// 1 picture of theirs offered for 1 number of ours, summed over the meanings it was
    /// seen drawing there.
    struct Offer {
        private(set) var meanings: [(tag: String, count: Int)] = []
        private(set) var witnesses = 0
        private(set) var weight = 0.0
        /// The width the strongest meaning asked for.
        private(set) var width: Int?

        /// The meaning seen most, for the report; the first of equals, so runs agree.
        var meaning: String { meanings.max { ($0.count, $1.tag) < ($1.count, $0.tag) }?.tag ?? "" }

        mutating func add(_ tag: String, count: Int, weight: Double, width: Int?) {
            if count > (meanings.map(\.count).max() ?? 0) { self.width = width }
            meanings.append((tag, count))
            witnesses += count
            self.weight += weight
        }
    }
}
