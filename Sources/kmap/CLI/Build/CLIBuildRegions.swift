import Foundation

/// The ground a build covers: the regions named on the command line, and the country
/// each belongs to.
extension CLI {
    /// A refusal on the way to a recipe, carrying the words the user is told.
    struct Refusal: Error { let why: String }

    /// Several ids joined by `+` build one seamless map out of all of them. Each must
    /// exist and have an extract to download.
    static func chosenRegions(_ regionID: String, in index: RegionIndex) -> Result<[Region], Refusal> {
        var chosen: [Region] = []
        for id in regionID.split(separator: "+").map(String.init) {
            guard let found = index.region(id) else {
                return .failure(Refusal(why: "no region with id \"\(id)\" — try `kmap regions \(id)`"))
            }
            guard found.pbfURL != nil else {
                return .failure(Refusal(why: "\(found.name) has no downloadable extract — pick a sub-region"))
            }
            chosen.append(found)
        }
        return .success(chosen)
    }

    /// Region id to country id, walking up the tree until the parent is a continent.
    static func countries(of regions: [Region], in index: RegionIndex) -> [String: String] {
        var out: [String: String] = [:]
        for region in regions {
            var current = region
            while let parentID = current.parentID, let parent = index.region(parentID),
                parent.parentID != nil
            {
                current = parent
            }
            out[region.id] = current.id
        }
        return out
    }
}
