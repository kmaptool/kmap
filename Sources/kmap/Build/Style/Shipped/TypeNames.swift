import Foundation

/// The English and Russian names of the types the shipped styles draw, by kind and code.
/// See Assets/styles/type-names.txt.
enum TypeNames {
    static let all = parse(StyleAssets.typeNames)

    static func key(_ kind: MapElementKind, _ code: Int) -> String {
        "\(kind.rawValue) 0x\(String(code, radix: 16))"
    }

    /// `<kind> <code>|<English>|<Russian>` rows; a row it cannot read is left out.
    static func parse(_ text: String) -> [String: (english: String, russian: String)] {
        var out: [String: (english: String, russian: String)] = [:]
        for raw in text.components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#") else { continue }
            let fields = line.components(separatedBy: "|")
            let head = fields[0].split(separator: " ")
            guard fields.count == 3, head.count == 2, let kind = MapElementKind(rawValue: String(head[0])),
                let code = Int(head[1].lowercased().replacingOccurrences(of: "0x", with: ""), radix: 16)
            else { continue }
            out[key(kind, code)] = (fields[1], fields[2])
        }
        return out
    }
}
