import Foundation

extension TileSplitter {
    /// Which nodes an earlier input already wrote, where several inputs overlap. Ids ascend
    /// within each extract, so a repeat is found by merging, a cursor per earlier file
    /// walking it in step with the arriving ids; an extract whose ids are not sorted falls
    /// back to a set of every id seen.
    struct NodeRepeats {
        let nodes: NodeAreas
        let mergeable: Bool
        var earlier: [NodeAreas.FileCursor] = []
        var seen: Set<Int64> = []

        init(_ nodes: NodeAreas, inputs: Int) {
            self.nodes = nodes
            mergeable = !nodes.filesInterleave && nodes.fileEnds.count == inputs
        }

        mutating func start(file: Int) {
            earlier = mergeable ? nodes.fileCursors(before: file) : []
        }

        mutating func repeated(_ id: Int64) -> Bool {
            guard mergeable else { return !seen.insert(id).inserted }
            for i in earlier.indices where earlier[i].contains(id) { return true }
            return false
        }
    }
}
