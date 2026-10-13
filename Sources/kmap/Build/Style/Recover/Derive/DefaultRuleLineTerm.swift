import Foundation

extension DefaultRuleBook.Line {
    /// 1 term of a plain condition, read once: `k=v`, `k=*`, `k!=v`, `k!=*`, or a number
    /// compared with `<`, `<=`, `>` or `>=` by the first number in the value. A term kmap
    /// cannot judge stays one, in its place: the terms before it still decide first.
    enum Term {
        case equals(key: String, value: String)
        case differs(key: String, value: String)
        case compares(key: String, op: String, limit: Double)
        case unknown

        init(_ term: String) {
            for op in ["!=", ">=", "<=", "=", ">", "<"] {
                guard let at = term.range(of: op) else { continue }
                let key = term[..<at.lowerBound].trimmingCharacters(in: .whitespaces)
                var value = term[at.upperBound...].trimmingCharacters(in: .whitespaces)
                if value.count >= 2, let first = value.first, "'\"".contains(first), value.last == first {
                    value = String(value.dropFirst().dropLast())
                }
                guard !key.isEmpty, !key.hasPrefix("mkgmap:") else {
                    self = .unknown
                    return
                }
                switch op {
                case "=": self = .equals(key: key, value: value)
                case "!=": self = .differs(key: key, value: value)
                default:
                    guard let limit = Double(value) else {
                        self = .unknown
                        return
                    }
                    self = .compares(key: key, op: op, limit: limit)
                }
                return
            }
            self = .unknown
        }

        /// Whether the tags meet the term; nil where it cannot be judged. A value with no
        /// number fails a comparison, as in mkgmap.
        func holds(for tags: [String: String]) -> Bool? {
            switch self {
            case .equals(let key, let value): return value == "*" ? tags[key] != nil : tags[key] == value
            case .differs(let key, let value): return value == "*" ? tags[key] == nil : tags[key] != value
            case .compares(let key, let op, let limit):
                guard let number = tags[key].flatMap(DefaultRuleBook.Line.leadingNumber) else { return false }
                switch op {
                case ">": return number > limit
                case ">=": return number >= limit
                case "<": return number < limit
                default: return number <= limit
                }
            case .unknown: return nil
            }
        }
    }
}
