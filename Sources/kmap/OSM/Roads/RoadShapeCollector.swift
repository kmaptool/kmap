import Foundation

extension RoadNetworkLoader {
    /// First pass: the ways, and the node ids they will need.
    ///
    /// One instance per block, filled on whichever core is free. Obstacle words are interned
    /// where the blocks are joined, since a vocabulary shared between workers would need a lock.
    struct ShapeCollector: OSMSink {
        let wantedParts: OSMParts = .ways

        var network = RoadNetwork()
        var obstacleRefs: [Int64] = []
        /// The spelling of each obstacle in this block, in the order they were collected.
        var words: [String] = []

        /// Obstacle words fit a byte; past this many, the rest are filed under the first.
        private static let mostWords = 255

        private var keyKinds: [UInt8] = []

        mutating func begin(_ block: OSMBlock) {
            keyKinds = WayTags.keyKinds(of: block.strings)
        }

        mutating func clear() {
            network = RoadNetwork()
            obstacleRefs.removeAll(keepingCapacity: true)
            words.removeAll(keepingCapacity: true)
        }

        /// Appends another block's collection after this one's, its words interned here.
        mutating func absorb(_ part: ShapeCollector, vocabulary: inout [String: UInt8]) throws {
            // Points are numbered in 32 bits; a continent's buildings can pass that.
            guard network.refs.count + part.network.refs.count <= Int(Int32.max),
                obstacleRefs.count + part.obstacleRefs.count <= Int(Int32.max)
            else { throw RoadNetworkLoader.Trouble.tooLarge }
            network.wayID.append(contentsOf: part.network.wayID)
            network.level.append(contentsOf: part.network.level)
            let refBase = Int32(network.refs.count)
            network.refs.append(contentsOf: part.network.refs)
            for start in part.network.start.dropFirst() { network.start.append(refBase + start) }

            let obstacleBase = Int32(obstacleRefs.count)
            obstacleRefs.append(contentsOf: part.obstacleRefs)
            for start in part.network.obstacleStart.dropFirst() {
                network.obstacleStart.append(obstacleBase + start)
            }
            network.passages.formUnion(part.network.passages)
            network.obstacleKind.append(contentsOf: part.network.obstacleKind)
            network.obstacleHeight.append(contentsOf: part.network.obstacleHeight)
            for word in part.words { network.obstacleWord.append(intern(word, vocabulary: &vocabulary)) }
        }

        private mutating func intern(_ word: String, vocabulary: inout [String: UInt8]) -> UInt8 {
            if let known = vocabulary[word] { return known }
            guard network.vocabulary.count < Self.mostWords else {
                // Past the last number: no word, which the label reads as an obstacle,
                // rather than the first word met.
                if network.vocabulary.count == Self.mostWords { network.vocabulary.append("") }
                return UInt8(Self.mostWords)
            }
            let made = UInt8(network.vocabulary.count)
            network.vocabulary.append(word)
            vocabulary[word] = made
            return made
        }

        mutating func way(
            id: Int64,
            refs: ArraySlice<Int64>,
            keys: ArraySlice<Int32>,
            values: ArraySlice<Int32>,
            block: OSMBlock
        ) {
            guard refs.count >= RoadNetwork.leastPoints else { return }
            let tags = WayTags(keys: keys, values: values, block: block, kinds: keyKinds)
            if let highway = tags.highway, OSMCensus.roadKinds.contains(highway) {
                network.wayID.append(id)
                network.level.append(
                    RoadNetworkLoader.level(layer: tags.layer, bridge: tags.bridge, tunnel: tags.tunnel)
                )
                network.refs.append(contentsOf: refs)
                network.start.append(Int32(network.refs.count))
                if tags.tunnel == "building_passage" { network.passages.insert(id) }
                return
            }
            guard let kind = tags.obstacleKind else { return }
            network.obstacleKind.append(kind.rawValue)
            network.obstacleWord.append(0)
            words.append(tags.word(for: kind))
            network.obstacleHeight.append(tags.height)
            obstacleRefs.append(contentsOf: refs)
            network.obstacleStart.append(Int32(obstacleRefs.count))
        }
    }
}
