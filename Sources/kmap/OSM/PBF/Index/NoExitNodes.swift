import Foundation

/// One block's nodes, as `BlockNodes` gathers them, and those of them tagged `noexit=yes`,
/// a dead end on purpose, or a gate: the road repair joins neither. Its own sink, so the
/// passes that read positions alone pay nothing for the tags.
struct NoExitNodes: OSMSink {
    let wantedParts: OSMParts = .nodes

    var nodes = BlockNodes()
    var noExit: [Int64] = []
    var gates: [Int64] = []
    /// Where `noexit`, `yes`, `barrier` and the gates sit in this block's string table,
    /// found once as the block begins: then each tag is integer comparisons.
    private var noExitKey: Int32 = -1
    private var yesValue: Int32 = -1
    private var barrierKey: Int32 = -1
    private var gateValues: Set<Int32> = []

    private static let noExitBytes = Array("noexit".utf8), yesBytes = Array("yes".utf8)
    private static let barrierBytes = Array("barrier".utf8)
    private static let gateBytes = RepairPlanner.gateWords.map { Array($0.utf8) }

    /// 1 walk over the string table for every word asked.
    mutating func begin(_ block: OSMBlock) {
        noExitKey = -1
        yesValue = -1
        barrierKey = -1
        gateValues = []
        let strings = block.strings
        for at in 0..<strings.count {
            guard let bytes = strings.bytes(at), bytes.count >= 3, bytes.count <= 12 else { continue }
            let index = Int32(at)
            if bytes.elementsEqual(Self.noExitBytes) {
                noExitKey = index
            } else if bytes.elementsEqual(Self.yesBytes) {
                yesValue = index
            } else if bytes.elementsEqual(Self.barrierBytes) {
                barrierKey = index
            } else if Self.gateBytes.contains(where: { $0.count == bytes.count && bytes.elementsEqual($0) }) {
                gateValues.insert(index)
            }
        }
        if barrierKey < 0 { gateValues = [] }
    }

    mutating func node(
        id: Int64,
        lat latitude: Double,
        lon longitude: Double,
        tags: ArraySlice<Int32>,
        block: OSMBlock
    ) {
        nodes.node(id: id, lat: latitude, lon: longitude, tags: tags, block: block)
        guard !tags.isEmpty, (noExitKey >= 0 && yesValue >= 0) || !gateValues.isEmpty else { return }
        // A node may be both: each is noted once.
        var at = tags.startIndex
        var dead = false, gate = false
        while at + 1 < tags.endIndex {
            if !dead, tags[at] == noExitKey && tags[at + 1] == yesValue {
                noExit.append(id)
                dead = true
            } else if !gate, tags[at] == barrierKey && gateValues.contains(tags[at + 1]) {
                gates.append(id)
                gate = true
            }
            at += 2
        }
    }

    mutating func clear() {
        nodes.clear()
        noExit.removeAll(keepingCapacity: true)
        gates.removeAll(keepingCapacity: true)
    }
}
