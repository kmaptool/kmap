import Foundation

/// The conventional Garmin type vocabulary — what receivers and the classic maps
/// expect a code to stand for. The rules are the authority wherever they speak; this
/// table answers for the codes they do not name, so a free slot in the type list is
/// picked with its convention in view rather than blind. A TYP may repurpose any of
/// these, which is exactly what the list then shows instead.
enum GarminStandard {

    private static let table: [String: (ru: String, en: String)] = {
        var out: [String: (ru: String, en: String)] = [:]
        for line in StyleAssets.garminTypes.split(whereSeparator: \.isNewline) {
            guard !line.hasPrefix("#") else { continue }
            let fields = line.split(separator: "|")
            guard fields.count == 4 else { continue }
            out["\(fields[0])\(fields[1])"] = (String(fields[2]), String(fields[3]))
        }
        return out
    }()

    /// The universal meaning of a code, or nil where the vocabulary is silent. A
    /// point is looked up with its subtype first — the house vocabulary names exact
    /// codes — and by its type family second.
    static func meaning(_ kind: MapElementKind, _ code: Int, russian: Bool) -> String? {
        if kind == .point {
            let exactKey = "P\(String(format: "%04x", code > 0xFF ? code : code << 8))"
            if let found = table[exactKey] { return russian ? found.ru : found.en }
            let family = "P\(String(format: "%02x", code > 0xFF ? code >> 8 : code))"
            guard let found = table[family] else { return nil }
            return russian ? found.ru : found.en
        }
        let key = "\(letter(kind))\(String(format: "%02x", code))"
        guard let found = table[key] else { return nil }
        return russian ? found.ru : found.en
    }

    /// The meaning only where the vocabulary names this exact code — for a point, the
    /// entry carrying its subtype, never the family: "Food & drink" is not a name for
    /// one dish in it. What the name column may use; the family stays a hint.
    static func exactMeaning(_ kind: MapElementKind, _ code: Int,
                             russian: Bool) -> String? {
        if kind == .point {
            let key = "P\(String(format: "%04x", code > 0xFF ? code : code << 8))"
            guard let found = table[key] else { return nil }
            return russian ? found.ru : found.en
        }
        return meaning(kind, code, russian: russian)
    }

    private static func letter(_ kind: MapElementKind) -> String {
        switch kind {
        case .point: return "P"
        case .line: return "L"
        case .polygon: return "A"
        }
    }
}
