import Foundation

extension RoadNetworkLoader {
    /// The tags of a way that make it a road or an obstacle.
    struct WayTags {
        var highway: String?, barrier: String?, natural: String?
        var waterway: String?, manMade: String?, building = false
        var layer = "0", bridge = "no", tunnel = "no", height: Float = .nan

        /// The keys read, numbered from 1 in this order; 0 is any other.
        private static let keyNames = [
            "highway", "barrier", "natural", "waterway", "man_made", "building",
            "layer", "bridge", "tunnel", "height", "est_height"
        ].map { Array($0.utf8) }

        /// What each entry of a block's string table is as a key, found once per block.
        static func keyKinds(of strings: StringPool) -> [UInt8] {
            (0..<strings.count).map { at in
                guard let bytes = strings.bytes(at), bytes.count >= 5, bytes.count <= 10 else { return 0 }
                for (i, name) in keyNames.enumerated() where name.count == bytes.count && bytes.elementsEqual(name) {
                    return UInt8(i + 1)
                }
                return 0
            }
        }

        @inline(__always)
        init(keys: ArraySlice<Int32>, values: ArraySlice<Int32>, block: OSMBlock, kinds: [UInt8]) {
            for (i, key) in keys.enumerated() {
                guard i < values.count else { break }
                // The value's text only for a key that is kept: most are not.
                let value = Int(values[values.startIndex + i])
                switch key >= 0 && Int(key) < kinds.count ? kinds[Int(key)] : 0 {
                case 1: highway = block.text(value)
                case 2: barrier = block.text(value)
                case 3: natural = block.text(value)
                case 4: waterway = block.text(value)
                case 5: manMade = block.text(value)
                // building=no says the outline is not a building.
                case 6: building = block.text(value) != "no"
                case 7: layer = block.text(value)
                case 8: bridge = block.text(value)
                case 9: tunnel = block.text(value)
                case 10, 11: height = Self.metres(block.text(value))
                default: break
                }
            }
        }

        /// A height as OSM writes one: a number, maybe with a decimal comma and a unit after.
        static func metres(_ text: String) -> Float {
            Float(text.split(separator: " ").first.map(String.init)?.replacingOccurrences(of: ",", with: ".") ?? "")
                ?? .nan
        }

        var obstacleKind: ObstacleKind? {
            RoadNetworkLoader.obstacleKind(
                barrier: barrier,
                natural: natural,
                waterway: waterway,
                manMade: manMade,
                building: building
            )
        }

        /// What an obstacle is called on the map: the OSM value it was recognised by.
        func word(for kind: ObstacleKind) -> String {
            switch kind {
            case .fence, .barrier: return barrier ?? "barrier"
            case .cliff, .ravine: return natural ?? "cliff"
            case .water: return waterway ?? "water"
            case .embankment: return manMade ?? "embankment"
            case .building: return "building"
            }
        }
    }
}
