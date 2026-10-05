import Foundation

/// The routing graph, built only around the ends in question.
///
/// A whole country's road network will not fit in memory as an adjacency list, and it
/// does not need to: a detour is given up on after 400 m, so a way further than that
/// from every candidate can never appear in an answer. The coarse cell here is about
/// 550 m, comfortably wider than that cap.
struct LocalGraph {
    private var index: [Int64: Int32] = [:]
    /// The edges the graph was built with, a node's in a row: `edgeNode` and `edgeStep`
    /// from `firstEdge[node]` up to `firstEdge[node + 1]`. 1 array for them all: a list
    /// per node costs an allocation or more for every node of the region.
    /// Counted in `Int`: 2 times the segments of a large region would overflow `Int32`.
    private var firstEdge: [Int] = [0]
    private var edgeNode: [Int32] = []
    private var edgeStep: [Double] = []
    /// Edges added since, by the repairs themselves: few, and so a list per node.
    private var added: [[(node: Int32, step: Double)]] = []

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
        // A detour goes out and comes back within the search, so half of it away; far north
        // a coarse cell is narrower than that east to west.
        let wanted = RoadRepair.cells(
            around: candidates,
            of: network,
            cell: Self.coarseDegrees,
            reach: RepairPlanner.search / 2
        )
        // Found across the cores, numbered here in the order 1 walk would number them.
        let lanes = Self.segments(of: network, startingIn: wanted)
        let count = lanes.reduce(0) { $0 + $1.count }
        var ends: [(a: Int32, b: Int32)] = []
        ends.reserveCapacity(count)
        var degree: [Int32] = []
        for lane in lanes {
            for start in lane {
                let a = Int(start)
                let i = slot(network.refs[a], counting: &degree), j = slot(network.refs[a + 1], counting: &degree)
                degree[Int(i)] += 1
                degree[Int(j)] += 1
                ends.append((i, j))
            }
        }
        // Each node's row, then every edge into both its rows, in the order a list per
        // node would have taken them.
        firstEdge = [Int](repeating: 0, count: degree.count + 1)
        for node in degree.indices { firstEdge[node + 1] = firstEdge[node] + Int(degree[node]) }
        var next = Array(firstEdge.dropLast())
        edgeNode = [Int32](repeating: 0, count: count * 2)
        edgeStep = [Double](repeating: 0, count: count * 2)
        var at = 0
        for lane in lanes {
            for start in lane {
                let a = Int(start), b = a + 1
                let kx = RoadRepair.metresPerLonDegree(at: network.lat[a])
                let dx = (network.lon[b] - network.lon[a]) * kx
                let dy = (network.lat[b] - network.lat[a]) * RoadRepair.metresPerDegree
                let metres = (dx * dx + dy * dy).squareRoot()
                let (i, j) = ends[at]
                at += 1
                edgeNode[next[Int(i)]] = j
                edgeStep[next[Int(i)]] = metres
                next[Int(i)] += 1
                edgeNode[next[Int(j)]] = i
                edgeStep[next[Int(j)]] = metres
                next[Int(j)] += 1
            }
        }
    }

    /// The node's number while the graph is being built, its degree counted beside it.
    private mutating func slot(_ ref: Int64, counting degree: inout [Int32]) -> Int32 {
        if let known = index[ref] { return known }
        let made = Int32(degree.count)
        index[ref] = made
        degree.append(0)
        added.append([])
        best.append(.infinity)
        stamp.append(0)
        return made
    }

    /// The coarse cell, about 550 m: wider than the detour cap.
    private static let coarseDegrees = 0.005
    /// Ways handed to a core at a time.
    private static let waysPerLane = 1 << 14

    /// The first point of every segment starting in a wanted cell, a list per lane of ways.
    private static func segments(of network: RoadNetwork, startingIn wanted: CellTable) -> [[Int32]] {
        let ways = network.wayCount
        let lanes = (ways + waysPerLane - 1) / waysPerLane
        let found = Locked([[Int32]](repeating: [], count: lanes))
        DispatchQueue.concurrentPerform(iterations: lanes) { lane in
            var starts: [Int32] = []
            for way in lane * waysPerLane..<min(ways, (lane + 1) * waysPerLane) {
                let range = network.points(of: way)
                for a in range.lowerBound..<(range.upperBound - 1)
                where wanted.contains(RoadRepair.key(network.lat[a], network.lon[a], coarseDegrees)) {
                    starts.append(Int32(a))
                }
            }
            found.withLock { $0[lane] = starts }
        }
        return found.withLock { $0 }
    }

    private mutating func slot(_ ref: Int64) -> Int32 {
        if let known = index[ref] { return known }
        let made = Int32(added.count)
        index[ref] = made
        added.append([])
        best.append(.infinity)
        stamp.append(0)
        return made
    }

    /// Tell the graph about an edge -- used while building, and again for each repair, so
    /// that later candidates judge the map as the earlier ones have left it.
    mutating func link(_ a: Int64, _ b: Int64, _ metres: Double) {
        let i = slot(a), j = slot(b)
        added[Int(i)].append((node: j, step: metres))
        added[Int(j)].append((node: i, step: metres))
    }

    /// One node stands in for another: everything the old one reached, the new one reaches.
    mutating func adopt(_ gone: Int64, into stands: Int64) {
        guard let from = index[gone] else { return }
        let to = slot(stands)
        // The rows are read before anything is added: the node may be its own neighbour.
        var edges: [(node: Int32, step: Double)] = []
        for at in builtEdges(of: from) { edges.append((edgeNode[at], edgeStep[at])) }
        edges += added[Int(from)]
        for edge in edges {
            added[Int(to)].append(edge)
            added[Int(edge.node)].append((node: to, step: edge.step))
        }
    }

    /// Shortest distance from one node to either of two others, or nil past the cap.
    mutating func detour(
        from source: Int64,
        to targets: (Int64, Int64),
        cap: Double
    ) -> Double? {
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
            for edge in builtEdges(of: node) {
                reach(edgeNode[edge], distance + edgeStep[edge], mark, &queue)
            }
            for edge in added[Int(node)] { reach(edge.node, distance + edge.step, mark, &queue) }
        }
        return nil
    }

    /// Where the edges the graph was built with sit for a node; none for a node added since.
    @inline(__always)
    private func builtEdges(of node: Int32) -> Range<Int> {
        let node = Int(node)
        guard node + 1 < firstEdge.count else { return 0..<0 }
        return firstEdge[node]..<firstEdge[node + 1]
    }

    @inline(__always)
    private mutating func reach(_ node: Int32, _ through: Double, _ mark: Int32, _ queue: inout Heap) {
        let at = Int(node)
        if stamp[at] != mark || through < best[at] {
            stamp[at] = mark
            best[at] = through
            queue.push(through, node)
        }
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
