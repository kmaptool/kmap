import Foundation

/// The gates a gap passes before it is closed: what stands between the ends, whether the
/// lines only run alongside, and what the ground does.
extension RepairPlanner {
    /// Whether the way is still within `reach` metres of the other line 30 metres back
    /// from its end, which separates a pavement from a switchback arriving shallow.
    private func stillBeside(
        candidate: RoadRepair.Candidate,
        at: Int,
        kx: Double,
        reach: Double,
        segment: Int
    ) -> Bool {
        let way = Int(candidate.way)
        let lo = Int(network.start[way]), hi = Int(network.start[way + 1])
        var i = at
        let step = candidate.atEnd ? -1 : 1
        var travelled = 0.0
        var plat = network.lat[i], plon = network.lon[i]
        while i + step >= lo, i + step < hi, travelled < Self.lookBack {
            i += step
            let nlat = network.lat[i], nlon = network.lon[i]
            let dx = (nlon - plon) * kx, dy = (nlat - plat) * RoadRepair.metresPerDegree
            travelled += (dx * dx + dy * dy).squareRoot()
            plat = nlat; plon = nlon
        }
        // A stub too short to judge is refused.
        if travelled < Self.stubLength { return true }
        // Distance to the INFINITE line through the matched segment, not to the other
        // way's polyline: a way duplicating that line stays at distance zero however far
        // back one walks, whereas a switchback's tail is genuinely off it.
        let ax = (network.lon[segment] - plon) * kx
        let ay = (network.lat[segment] - plat) * RoadRepair.metresPerDegree
        let bx = (network.lon[segment + 1] - plon) * kx
        let by = (network.lat[segment + 1] - plat) * RoadRepair.metresPerDegree
        let dx = bx - ax, dy = by - ay
        let length = (dx * dx + dy * dy).squareRoot()
        if length == 0 { return true }
        return abs(ax * dy - ay * dx) / length <= reach
    }

    /// Barriers that close a way rather than slow it: an end on one is shut out.
    static let gateWords: Set<String> = ["gate", "lift_gate", "swing_gate", "sliding_gate", "wicket_gate", "turnstile"]

    enum Gate {
        case refused(String)
        case allowed(Blockage?)
    }

    /// Everything that can stop a repair before the routing test is reached.
    func stopped(_ gap: Gap, obstacles: CellTable) -> Gate {
        let p = gap.origin, q = gap.landing
        // An end on a fence or a building is a gate or a door, as is a landing on one: private
        // ground or indoors. A building passage is a street and meets the wall it runs through,
        // on either of the 2 lines; a fence or a gate still shuts it.
        let passage = [gap.candidate.way, gap.candidate.otherWay].contains {
            network.passages.contains(network.wayID[Int($0)])
        }
        for point in [p, q] {
            let through = obstaclesThrough(
                point.lat,
                point.lon,
                grid: obstacles,
                cell: RoadRepair.cellDegrees,
                closing: true
            )
            if !passage, through.contains(where: { $0.kind == .building }) {
                return .refused(Verdict.stoppedBy(Verdict.building))
            }
            if through.contains(where: { $0.kind.isImpassable && $0.kind != .building }) {
                return .refused(Verdict.stoppedBy(Verdict.fence))
            }
            // A gate drawn as a line of its own across the way.
            if let gate = through.first(where: { Self.gateWords.contains($0.word) }) {
                return .refused(Verdict.stoppedBy(gate.word))
            }
        }
        // A gate mapped as a node of the road: the end itself, or the node it would land on.
        if network.gates.contains(gap.ref) || network.gates.contains(network.refs[gap.at]) {
            return .refused(Verdict.stoppedBy("gate"))
        }
        for node in [gap.segment, gap.segment + 1] where network.gates.contains(network.refs[node]) {
            let dx = (network.lon[node] - q.lon) * gap.kx
            let dy = (network.lat[node] - q.lat) * RoadRepair.metresPerDegree
            if (dx * dx + dy * dy).squareRoot() <= Self.slip { return .refused(Verdict.stoppedBy("gate")) }
        }
        // A dead end mapped as one takes no join from another line either.
        for node in [gap.segment, gap.segment + 1] where network.noExit.contains(network.refs[node]) {
            let dx = (network.lon[node] - q.lon) * gap.kx
            let dy = (network.lat[node] - q.lat) * RoadRepair.metresPerDegree
            if (dx * dx + dy * dy).squareRoot() <= Self.slip { return .refused(Verdict.deadEnd) }
        }
        var blocked = blockedBy(p.lat, p.lon, q.lat, q.lon, grid: obstacles, cell: RoadRepair.cellDegrees)
        if let refusal = refusal(by: blocked) { return .refused(refusal) }
        // A pavement running alongside a road is not a junction, however close it comes.
        if runsAlongside(gap) { return .refused(Verdict.alongside) }
        if let (reason, height) = groundSays(p.lat, p.lon, q.lat, q.lon, distance: gap.distance) {
            if !bridging { return .refused(Verdict.stoppedBy(reason.rawValue)) }
            // The ground's own height counts as an obstacle's does: past `tooHigh` nothing
            // is getting over it.
            if height.isFinite, height > Self.tooHigh {
                return .refused(Verdict.tooHigh(reason.rawValue, Self.tooHigh))
            }
            if blocked == nil {
                blocked = Blockage(
                    kind: reason == .ravine ? .ravine : .cliff,
                    word: reason.rawValue,
                    height: Float(height)
                )
            }
        }
        return .allowed(blocked)
    }

    /// Why an obstacle in the way refuses the repair outright, if it does.
    private func refusal(by blocked: Blockage?) -> String? {
        guard let hit = blocked else { return nil }
        if hit.kind.isImpassable {
            return Verdict.stoppedBy(hit.kind == .building ? Verdict.building : Verdict.fence)
        }
        if !bridging { return Verdict.stoppedBy(hit.word) }
        if hit.height.isFinite, Double(hit.height) > Self.tooHigh { return Verdict.tooHigh(hit.word, Self.tooHigh) }
        return nil
    }

    /// Whether the way arrives shallow and stays beside the other line: a pavement, not
    /// a junction.
    private func runsAlongside(_ gap: Gap) -> Bool {
        let p = gap.origin, kx = gap.kx
        let neighbour = gap.candidate.atEnd ? gap.at - 1 : gap.at + 1
        let v1 = ((p.lon - network.lon[neighbour]) * kx, (p.lat - network.lat[neighbour]) * RoadRepair.metresPerDegree)
        let v2 = ((gap.b.lon - gap.a.lon) * kx, (gap.b.lat - gap.a.lat) * RoadRepair.metresPerDegree)
        let n1 = (v1.0 * v1.0 + v1.1 * v1.1).squareRoot()
        let n2 = (v2.0 * v2.0 + v2.1 * v2.1).squareRoot()
        guard n1 > 0 && n2 > 0 else { return false }
        let cosine = abs(v1.0 * v2.0 + v1.1 * v2.1) / (n1 * n2)
        let angle = acos(max(-1, min(1, cosine))) * Self.halfTurnDegrees / .pi
        // The arrival angle alone cannot tell a pavement from a switchback, both arriving
        // shallow, so a shallow angle counts as alongside only when the way is still beside
        // the other line 30 metres back.
        let along = gap.candidate.along
        guard angle < Self.shallowDegrees && along > Self.nearStart && along < Self.nearEnd else { return false }
        return stillBeside(
            candidate: gap.candidate,
            at: gap.at,
            kx: kx,
            reach: gap.distance + limit,
            segment: gap.segment
        )
    }

    /// What the ground says against joining; the word is what the verdict prints.
    private enum Ground: String { case drop, ravine, face }

    private func groundSays(
        _ plat: Double,
        _ plon: Double,
        _ qlat: Double,
        _ qlon: Double,
        distance: Double
    ) -> (Ground, height: Double)? {
        guard let terrain, distance > Self.groundMinimum else { return nil }
        guard let here = terrain.elevation(plat, plon),
            let there = terrain.elevation(qlat, qlon)
        else { return nil }
        if abs(here - there) > Self.step { return (.drop, abs(here - there)) }
        if let middle = terrain.elevation((plat + qlat) / 2, (plon + qlon) / 2),
            min(here, there) - middle > Self.dip
        {
            return (.ravine, min(here, there) - middle)
        }
        if let steep = terrain.slope(plat, plon), steep > Self.cliffDegrees { return (.face, .nan) }
        return nil
    }
}
