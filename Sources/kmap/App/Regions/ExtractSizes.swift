import Foundation

/// The download size of each region's extract, asked of the server once per region and
/// kept. Shared by the region tree and the build form, which both show the figure.
@MainActor
final class ExtractSizes {
    private var bytes: [String: Int64] = [:]
    private var probing: Set<String> = []
    /// When a region's probe last failed: asked again only after a pause, or every frame
    /// would send another request while the network is down.
    private var failed: [String: Date] = [:]
    private static let retryAfter: TimeInterval = 60

    subscript(id: String) -> Int64? { bytes[id] }
    subscript(region: Region) -> Int64? { bytes[region.id] }

    func isProbing(_ region: Region) -> Bool { probing.contains(region.id) }

    /// Asks once; a region with no extract, or one already asked about, is left alone.
    func probe(_ region: Region) {
        guard let url = region.pbfURL, bytes[region.id] == nil, !probing.contains(region.id),
            failed[region.id].map({ Date().timeIntervalSince($0) > Self.retryAfter }) ?? true
        else { return }
        probing.insert(region.id)
        Task { [weak self] in
            let info = try? await Downloader.probe(url)
            guard let self else { return }
            await MainActor.run {
                self.probing.remove(region.id)
                if let info { self.bytes[region.id] = info.size } else { self.failed[region.id] = Date() }
            }
        }
    }
}
