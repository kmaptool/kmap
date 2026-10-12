import Foundation

extension StylePort {
    /// Whether their code bearing our number means what our number means: only where it
    /// mostly draws 1 of our number's meanings. Their 0x2f08 is a bus stop, our 0x2f08 a
    /// station.
    struct Agreement {
        /// Their code's key to the meaning it is seen drawing most.
        private var dominant: [String: (tag: String, count: Int)] = [:]
        private var meanings: [MapElementKind: [Int: Set<String>]] = [:]
        /// The meanings a rule of ours names, which a `key=*` fallback never reaches.
        private var named: [MapElementKind: Set<String>] = [:]

        init(codesByTag: [String: [String: Int]], ourCodes: [MapElementKind: [String: Set<Int>]]) {
            // In the meanings' own order, so a tie falls the same way in every run.
            for (tag, drawn) in codesByTag.sorted(by: { $0.key < $1.key }) {
                for (key, count) in drawn where count > (dominant[key]?.count ?? 0) { dominant[key] = (tag, count) }
            }
            for (kind, byTag) in ourCodes {
                named[kind] = Set(byTag.keys)
                for (tag, numbers) in byTag {
                    for number in numbers { meanings[kind, default: [:]][number, default: []].insert(tag) }
                }
            }
        }

        func holds(theirs: Int, ours: Int, kind: MapElementKind) -> Bool {
            guard theirs == ours, let tag = dominant[StylePort.key(kind, theirs)]?.tag,
                let ourMeanings = meanings[kind]?[ours]
            else { return false }
            if ourMeanings.contains(tag) { return true }
            // A value no rule of ours names reaches our `key=*` fallback.
            guard let key = tag.split(separator: "=").first, named[kind]?.contains(tag) != true else { return false }
            return ourMeanings.contains(key + "=*")
        }
    }
}
