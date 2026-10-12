import Foundation

/// The inside of a type bracket.
struct RoadTwinType {
    let code: Int
    let codeText: String
    var options: [(key: String, value: String?)] = []

    private static let valued: Set<String> = ["level", "resolution", "default_name", "road_class", "road_speed"]
    private static let flags: Set<String> = [
        "continue", "propagate", "with_actions", "withactions", "no_propagate", "copy", "oneway", "access"
    ]
    static let continuation: Set<String> = ["continue", "propagate", "with_actions", "withactions", "no_propagate"]

    init?(_ inside: Substring) {
        var words: [String] = []
        var current = ""
        var quote: Character?
        for ch in inside {
            if let q = quote {
                current.append(ch)
                if ch == q { quote = nil }
            } else if ch == "'" || ch == "\"" {
                current.append(ch)
                quote = ch
            } else if ch == " " || ch == "\t" || ch == "=" {
                if !current.isEmpty { words.append(current) }
                current = ""
            } else {
                current.append(ch)
            }
        }
        if !current.isEmpty { words.append(current) }
        guard let first = words.first else { return nil }
        let lower = first.lowercased()
        guard let code = lower.hasPrefix("0x") ? Int(lower.dropFirst(2), radix: 16) : Int(lower) else { return nil }
        self.code = code
        codeText = first
        var at = 1
        while at < words.count {
            let key = words[at]
            if Self.valued.contains(key) {
                guard at + 1 < words.count else { return nil }
                options.append((key, words[at + 1]))
                at += 2
            } else if Self.flags.contains(key) {
                options.append((key, nil))
                at += 1
            } else {
                return nil
            }
        }
    }

    var isRoad: Bool { options.contains { $0.key == "road_class" || $0.key == "road_speed" } }

    /// `resolution 22` reaches the finest level, `resolution 20-23` and `level 1-3` do not.
    func reaches(_ finest: Int) -> Bool {
        for (key, value) in options {
            let bounds = (value ?? "").split(separator: "-").compactMap { Int($0) }
            guard let low = bounds.min(), let high = bounds.max() else { continue }
            if key == "resolution", bounds.count > 1 ? high < finest : low > finest { return false }
            if key == "level", bounds.count > 1, low > 0 { return false }
        }
        return true
    }

    static func written(code: String, _ options: [(key: String, value: String?)]) -> String {
        let words = options.map { key, value -> String in
            guard let value else { return key }
            return key + (key == "road_class" || key == "road_speed" ? "=" : " ") + value
        }
        return "[" + ([code] + words).joined(separator: " ") + "]"
    }
}
