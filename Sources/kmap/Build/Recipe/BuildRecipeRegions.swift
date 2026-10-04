import Foundation

extension BuildRecipe {
    /// The key a map is remembered by in the family-id registry: the region ids sorted and
    /// joined, so the same set always resolves to the same map.
    static func identityKey(_ regions: [Region]) -> String {
        regions.map(\.id).sorted().joined(separator: "+")
    }

    /// Geofabrik region ids whose OSM `name` is written in Cyrillic. Under code page 1252
    /// such names are silently transliterated to Latin.
    private static let cyrillicRegions: Set<String> = [
        "russia", "ukraine", "belarus", "bulgaria", "serbia", "macedonia",
        "montenegro", "kazakhstan", "kyrgyzstan", "mongolia", "tajikistan",
        "uzbekistan", "turkmenistan", "azerbaijan", "moldova", "abkhazia",
        "south-ossetia"
    ]

    /// Where the parent walk stops: a circular index would otherwise never end.
    private static let mostParentHops = 8

    /// The code page suggested for a region. Walks the region's parents, since a
    /// sub-region's own id says nothing about its alphabet while its parent's does.
    static func suggestedCodePage(for region: Region, in index: RegionIndex? = nil) -> Int {
        var cursor: Region? = region
        var hops = 0
        while let current = cursor, hops < mostParentHops {
            if cyrillicRegions.contains(current.id.lowercased()) { return CodePage.cyrillic }
            guard let index, let parentID = current.parentID else { break }
            cursor = index.region(parentID)
            hops += 1
        }
        // Fall back to a substring check for callers without the index to hand.
        let id = region.id.lowercased()
        return cyrillicRegions.contains(where: { id.contains($0) })
            ? CodePage.cyrillic : CodePage.westernEuropean
    }
}
