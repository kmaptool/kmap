import Foundation

extension ElementDumper {
    /// Every element of a map, as one table.
    ///
    /// One array of packed cells with a range per element, rather than an array per
    /// element: a country-sized map holds tens of millions of them.
    struct Dump: Sendable {
        var elements: [Element] = []
        var cells: [UInt64] = []
        /// The resolution each element is drawn at, where the walk recorded it. Held
        /// beside the elements rather than inside them: the binary dump's shape is a
        /// byte-compare anchor and does not change.
        var resolutions: [Int16] = []
        var count: Int { elements.count }

        func resolution(_ at: Int) -> Int? {
            at < resolutions.count ? Int(resolutions[at]) : nil
        }

        /// The vertex chain of one element.
        func chain(_ at: Int) -> ArraySlice<UInt64> {
            let element = elements[at]
            return cells[Int(element.from)..<Int(element.from + element.count)]
        }
    }
}
