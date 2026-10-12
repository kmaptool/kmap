import Foundation

/// Road meanings a ported style draws as another road: written into the ported TYP as
/// `; kmap:twin-as 0x08 highway=secondary_link 0x04`, read back by the build's road twins.
/// The road keeps its number and routes on it; its plain twin takes the other road's twin.
extension StylePort {
    /// The comment naming a road meaning drawn as another number's road.
    static let twinAs = "kmap:twin-as"

    /// Road meanings whose look their map draws on another number of ours: a secondary
    /// link wears their secondary road.
    static func twinsAs(_ ported: [Ported], rules: RuleSetIndex) -> [(ours: Int, meaning: String, as: Int)] {
        let lines = ported.filter { $0.kind == .line }
        func road(_ code: Int) -> Bool {
            rules.meaning(.line, code)?.rules.contains { $0.tail.contains("road_class") } == true
        }
        var wearing: [Int: Int] = [:]
        for port in lines.sorted(by: { $0.ours < $1.ours }) where wearing[port.theirs] == nil {
            wearing[port.theirs] = port.ours
        }
        var out: [(ours: Int, meaning: String, as: Int)] = []
        for port in lines where road(port.ours) {
            for rival in port.rivals where rival.theirs != port.theirs {
                guard let other = wearing[rival.theirs], other != port.ours else { continue }
                out.append((port.ours, rival.meaning, other))
            }
        }
        return out.sorted { ($0.ours, $0.meaning) < ($1.ours, $1.meaning) }
    }

    /// The borrowing a TYP declares, by road code.
    static func twinBorrowing(in typ: URL) -> [Int: [(tag: String, as: Int)]] {
        guard let text = TypSource.text(of: typ) else { return [:] }
        var out: [Int: [(tag: String, as: Int)]] = [:]
        for line in TextLines.of(text) {
            let words = line.split(separator: " ")
            guard words.count == 5, words[0] == ";", words[1] == twinAs,
                let road = Int(words[2].dropFirst(2), radix: 16), let other = Int(words[4].dropFirst(2), radix: 16)
            else { continue }
            out[road, default: []].append((String(words[3]), other))
        }
        return out
    }
}
