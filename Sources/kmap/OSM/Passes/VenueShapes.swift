import Foundation

extension VenueScan {
    /// First pass: the closed ways carrying a venue tag.
    struct Shapes: OSMSink {
        // Ways only: there is no relation handler here, and asking for relations unpacks
        // every one in the extract into the default no-op sink.
        let wantedParts: OSMParts = .ways

        var ids: [Int64] = []
        var tags: [String] = []
        var named: [Bool] = []
        var starts: [Int32] = [0]
        var refs: [Int64] = []

        mutating func clear() {
            ids.removeAll(keepingCapacity: true)
            tags.removeAll(keepingCapacity: true)
            named.removeAll(keepingCapacity: true)
            starts = [0]
            refs.removeAll(keepingCapacity: true)
        }

        mutating func way(
            id: Int64,
            refs list: ArraySlice<Int64>,
            keys: ArraySlice<Int32>,
            values: ArraySlice<Int32>,
            block: OSMBlock
        ) {
            guard list.count >= 4, list.first == list.last else { return }
            // A place can carry more than one of these keys, so the key is chosen by the
            // order of `VenueScan.keys`, not by the order the file stores the tags in.
            var present: [String: String] = [:]
            var hasName = false
            for (i, key) in keys.enumerated() {
                guard i < values.count else { break }
                let word = block.text(Int(key))
                if word == "name" { hasName = true }
                if VenueScan.keys.contains(word) {
                    present[word] = block.text(Int(values[values.startIndex + i]))
                }
            }
            var found: String?
            for key in VenueScan.keys {
                if let value = present[key] {
                    found = key + "=" + value
                    break
                }
            }
            guard let found else { return }
            ids.append(id)
            tags.append(found)
            named.append(hasName)
            refs.append(contentsOf: list)
            starts.append(Int32(refs.count))
        }
    }
}
