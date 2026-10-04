import Foundation

extension ElevationCost {
    /// What a source will cost, as far as it can be known.
    struct Estimate: Equatable {
        /// The source this line is about, as the form names it.
        let source: String
        /// Degree cells the map covers, after the outline trim.
        let cells: Int
        /// Of those, cells this source already holds on disk.
        let cached: Int
        /// Cells this source is asked for: not cached, and not already settled by a
        /// source listed before it.
        let wanted: Int
        /// Of those, cells the source actually publishes. The rest are open sea or
        /// ground it does not carry, and cost nothing.
        let published: Int
        /// What fetching them will come to, where that can be known.
        let bytes: Int64?
        /// True when every file was asked its size; false when the figure is a mean of
        /// `sampled` probes times the count.
        let exact: Bool
        /// How many real files were asked their size to arrive at the figure.
        let sampled: Int
        /// Archives to fetch, for sources shipping zones rather than single cells.
        let archives: Int
        /// Why there is no figure, where there is none.
        let note: String?
    }
}
