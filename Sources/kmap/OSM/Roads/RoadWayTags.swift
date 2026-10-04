import Foundation

extension RoadNetworkLoader {
    /// The tags of a way that make it a road or an obstacle.
    struct WayTags {
        var highway: String?, barrier: String?, natural: String?
        var waterway: String?, manMade: String?, building = false
        var layer = "0", bridge = "no", tunnel = "no", height: Float = .nan

        @inline(__always)
        init(keys: ArraySlice<Int32>, values: ArraySlice<Int32>, block: OSMBlock) {
            for (i, key) in keys.enumerated() {
                guard i < values.count else { break }
                // The value's text only for a key that is kept: most are not.
                let value = Int(values[values.startIndex + i])
                switch block.text(Int(key)) {
                case "highway": highway = block.text(value)
                case "barrier": barrier = block.text(value)
                case "natural": natural = block.text(value)
                case "waterway": waterway = block.text(value)
                case "man_made": manMade = block.text(value)
                case "building": building = true
                case "layer": layer = block.text(value)
                case "bridge": bridge = block.text(value)
                case "tunnel": tunnel = block.text(value)
                case "height", "est_height": height = Self.metres(block.text(value))
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
