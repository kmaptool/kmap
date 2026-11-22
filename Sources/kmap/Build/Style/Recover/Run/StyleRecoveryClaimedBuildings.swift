import Foundation

/// A building another rule claims, as their map draws it.
///
/// A town hall is credited to its amenity, so the tag's codes alone cannot tell the
/// area from a building their map lays over it. Told here from the sources: their code
/// that draws most of such buildings whatever claims them is the building's picture,
/// and no part of the look of an amenity, a shop or a castle.
extension StyleRecovery {
    /// The keys that claim a building, in the order a source is read by: a meaning's
    /// keys as `DefaultRuleBook.meaning` reads them, then the rest by name.
    static func claimOrder(_ keys: Set<String>) -> [String] {
        DefaultRuleBook.meaningKeys.filter(keys.contains) + keys.subtracting(DefaultRuleBook.meaningful).sorted()
    }

    /// What claims a building, as a tag: the first of `order` it carries. Nil for a
    /// source that is no building, or one nothing claims.
    static func claimant(of tags: [String: String], among order: [String]) -> String? {
        guard let building = tags[DefaultRuleBook.buildingKey], !building.isEmpty,
            building != DefaultRuleBook.noBuilding
        else { return nil }
        for key in order {
            if let value = tags[key], !value.isEmpty { return "\(key)=\(value)" }
        }
        return nil
    }

    /// Their area code that draws the buildings rules of ours claim, by any of `keys`:
    /// the one drawing the most of them, where it draws most of those each claimant
    /// claims, a claimant being a tag seen on `StylePort.fewestToPort` of them. Shown
    /// only by claimants of 2 keys: a picture that changes with what claims the
    /// building is the claimant's look, and 1 key cannot tell.
    /// - Returns: the code's key, how many claimed buildings it draws, and how many
    ///   were identified in all.
    static func claimedBuildingCode(
        in codes: [(key: String, value: Evidence.ForCode)],
        claimedBy keys: Set<String>,
        stop: StopFlag = StopFlag()
    ) -> (code: String?, drawn: Int, buildings: Int) {
        guard !keys.isEmpty else { return (nil, 0, 0) }
        let order = claimOrder(keys)
        // Each code read on its own, over every core: a building's code has millions.
        let read = Lanes.map(codes.count, lanes: codes.count) { at in
            var found: [String: [Int64]] = [:]
            guard codes[at].value.kind == .area else { return found }
            var seen = 0
            for (id, tags) in codes[at].value.sources {
                seen += 1
                if seen % StyleRecovery.progressStride == 0, stop.isRaised { break }
                guard let claimant = claimant(of: tags, among: order) else { continue }
                found[claimant, default: []].append(id)
            }
            return found
        }
        var claimed: [String: Set<Int64>] = [:]
        var drawn: [String: [String: Int]] = [:]
        for (at, found) in read.enumerated() {
            for (claimant, sources) in found {
                claimed[claimant, default: []].formUnion(sources)
                drawn[codes[at].key, default: [:]][claimant] = sources.count
            }
        }
        let buildings = claimed.values.reduce(0) { $0 + $1.count }
        func total(_ counts: [String: Int]) -> Int { counts.values.reduce(0, +) }
        guard let most = drawn.max(by: { (total($0.value), $1.key) < (total($1.value), $0.key) }) else {
            return (nil, 0, buildings)
        }
        let claimants = claimed.filter { $0.value.count >= StylePort.fewestToPort }
        let shown = Set(claimants.keys.map { $0.prefix { $0 != "=" } }).count > 1
        let whateverClaims = claimants.allSatisfy { (most.value[$0.key] ?? 0) * 2 > $0.value.count }
        return (shown && whateverClaims ? most.key : nil, total(most.value), buildings)
    }
}
