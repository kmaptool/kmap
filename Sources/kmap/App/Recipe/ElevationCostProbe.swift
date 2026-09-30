import Foundation

/// What the chosen elevation sources would cost to fetch, estimated for the source list
/// on the form and kept until the list changes. A pending, an answered and a stale
/// estimate stay distinguishable.
@MainActor
final class ElevationCostProbe {
    private(set) var estimates: [ElevationCost.Estimate] = []
    private(set) var isRunning = false
    private var estimatedFor = ""

    /// Re-estimates when the figure shown no longer belongs to `sources`. Empty sources,
    /// for a build without elevation, cost nothing and ask nothing.
    func refresh(sources: String, regions: [Region]) {
        guard sources != estimatedFor, !isRunning else { return }
        guard !sources.isEmpty else {
            estimates = []
            estimatedFor = ""
            return
        }
        isRunning = true
        Task { [weak self] in
            let estimate = await ElevationCost.estimate(sources: sources, regions: regions)
            await MainActor.run {
                guard let self else { return }
                self.estimates = estimate
                self.estimatedFor = sources
                self.isRunning = false
            }
        }
    }
}
