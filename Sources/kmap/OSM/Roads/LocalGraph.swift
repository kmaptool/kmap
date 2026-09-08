import Foundation

/// The routing graph, built only around the ends in question.
///
/// A whole country's road network will not fit in memory as an adjacency list, and it
/// does not need to: a detour is given up on after 400 m, so a way further than that
/// from every candidate can never appear in an answer. The coarse cell here is about
/// 550 m, comfortably wider than that cap.
struct LocalGraph {
    private var index: [Int64: Int32] = [:]
    private var neighbours: [[(node: Int32, step: Double)]] = []

    /// Distance found so far, and which search found it. Kept between searches and
    /// stamped rather than cleared: the graph has hundreds of thousands of nodes, a search
    /// touches a few dozen of them, and there is one search per gap. A dictionary built
    /// and thrown away for each was most of what the search cost.
    private var best: [Double] = []
    private var stamp: [Int32] = []
    private var currentStamp: Int32 = 0

    /// An empty graph, for links given one at a time.
    init() {}

    init(network: RoadNetwork, around candidates: [RoadRepair.Candidate]) {
        let coarse = 0.005
        var wanted = Set<Int64>()
        for candidate in candidates {
            let range = network.points(of: Int(candidate.way))
            let at = candidate.atEnd ? range.upperBound - 1 : range.lowerBound
            let here = RoadRepair.key(network.lat[at], network.lon[at], coarse)
            for dy in -1...1 {
                for dx in -1...1 { wanted.insert(here &+ (Int64(dy) << 32) &+ Int64(dx)) }
            }
        }

        for way in 0..<network.wayCount {
            let range = network.points(of: way)
            for a in range.lowerBound..<(range.upperBound - 1) {
                let key = RoadRepair.key(network.lat[a], network.lon[a], coarse)
                guard wanted.contains(key) else { continue }
                let b = a + 1
                let kx = RoadRepair.metresPerDegree * cos(network.lat[a] * .pi / 180)
                let dx = (network.lon[b] - network.lon[a]) * kx
                let dy = (network.lat[b] - network.lat[a]) * RoadRepair.metresPerDegree
                link(network.refs[a], network.refs[b], (dx * dx + dy * dy).squareRoot())
            }
        }
    }

    private mutating func slot(_ ref: Int64) -> Int32 {
        if let known = index[ref] { return known }
        let made = Int32(neighbours.count)
        index[ref] = made
        neighbours.append([])
        best.append(.infinity)
        stamp.append(0)
        return made
    }

    /// Tell the graph about an edge -- used while building, and again for each repair, so
    /// that later candidates judge the map as the earlier ones have left it.
    mutating func link(_ a: Int64, _ b: Int64, _ metres: Double) {
        let i = slot(a), j = slot(b)
        neighbours[Int(i)].append((node: j, step: metres))
        neighbours[Int(j)].append((node: i, step: metres))
    }

    /// One node stands in for another: everything the old one reached, the new one reaches.
    mutating func adopt(_ gone: Int64, into stands: Int64) {
        guard let from = index[gone] else { return }
        let to = slot(stands)
        for edge in neighbours[Int(from)] {
            neighbours[Int(to)].append(edge)
            neighbours[Int(edge.node)].append((node: to, step: edge.step))
        }
    }

    /// Shortest distance from one node to either of two others, or nil past the cap.
    mutating func detour(from source: Int64, to targets: (Int64, Int64),
                         cap: Double) -> Double? {
        guard let start = index[source] else { return nil }
        let first = index[targets.0], second = index[targets.1]
        guard first != nil || second != nil else { return nil }

        currentStamp += 1
        let mark = currentStamp
        best[Int(start)] = 0
        stamp[Int(start)] = mark

        var queue = Heap()
        queue.push(0, start)
        while let (distance, node) = queue.pop() {
            if distance > cap { return nil }
            if node == first || node == second { return distance }
            if stamp[Int(node)] == mark, distance > best[Int(node)] { continue }
            for edge in neighbours[Int(node)] {
                let through = distance + edge.step
                let at = Int(edge.node)
                if stamp[at] != mark || through < best[at] {
                    stamp[at] = mark
                    best[at] = through
                    queue.push(through, edge.node)
                }
            }
        }
        return nil
    }

    /// A plain binary heap. Swift ships no priority queue, and this one is entered
    /// millions of times, so it holds its pairs in two flat arrays and never allocates
    /// per entry.
    private struct Heap {
        private var distance: [Double] = []
        private var node: [Int32] = []

        mutating func push(_ d: Double, _ n: Int32) {
            distance.append(d)
            node.append(n)
            var child = distance.count - 1
            while child > 0 {
                let parent = (child - 1) / 2
                if distance[parent] <= distance[child] { break }
                distance.swapAt(parent, child)
                node.swapAt(parent, child)
                child = parent
            }
        }

        mutating func pop() -> (Double, Int32)? {
            guard !distance.isEmpty else { return nil }
            let top = (distance[0], node[0])
            distance[0] = distance[distance.count - 1]
            node[0] = node[node.count - 1]
            distance.removeLast()
            node.removeLast()
            var parent = 0
            while true {
                let left = parent * 2 + 1, right = left + 1
                var smallest = parent
                if left < distance.count && distance[left] < distance[smallest] { smallest = left }
                if right < distance.count && distance[right] < distance[smallest] { smallest = right }
                if smallest == parent { break }
                distance.swapAt(parent, smallest)
                node.swapAt(parent, smallest)
                parent = smallest
            }
            return top
        }
    }
}
