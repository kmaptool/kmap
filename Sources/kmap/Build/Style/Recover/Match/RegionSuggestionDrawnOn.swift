import Foundation

extension RegionSuggestion {
    /// The regions recover reads, the one holding most of the map's data first: every
    /// extract the map draws on the own ground of and that stands alone there. A region
    /// the map covers only in part counts too.
    static func groundToRead(for drawn: DrawnGround, index: RegionIndex) -> [Candidate] {
        stances(ofExtractsIn: index, on: drawn)
            .filter { $0.isDrawnOn && $0.standsAlone }
            .sorted { ($0.share, $1.region.id) > ($1.share, $0.region.id) }
    }

    /// The regions to fetch for a run to have ground enough: the first of `groundToRead`
    /// not in the cache, as many as bring what the cache holds of the map to
    /// `StyleRecovery.leastShare`.
    static func groundToFetch(for drawn: DrawnGround, index: RegionIndex) -> [Candidate] {
        var held = share(of: drawn, on: cachedHolders(drawnOn: drawn, index: index).map(\.ground))
        var out: [Candidate] = []
        for candidate in groundToRead(for: drawn, index: index) where !isCached(candidate.region) {
            guard held < StyleRecovery.leastShare else { break }
            out.append(candidate)
            held += candidate.share
        }
        return out
    }

    /// Every region holding any of the map's data on its own ground, the most first: what
    /// is left to name where none is ground to read, a region drawn on thinly or one the
    /// index gives in parts.
    static func groundToName(for drawn: DrawnGround, index: RegionIndex) -> [Candidate] {
        stances(ofExtractsIn: index, on: drawn)
            .filter { $0.share > 0 }
            .sorted { ($0.share, $1.region.id) > ($1.share, $0.region.id) }
    }

    /// Whether the region's extract is in the cache a build reads.
    static func isCached(_ region: Region) -> Bool {
        FileTools.exists(cacheDestination(for: region))
    }
}
