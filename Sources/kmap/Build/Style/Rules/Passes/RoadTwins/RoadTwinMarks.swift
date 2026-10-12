import Foundation

/// Action braces and type brackets, outside quotes and `${tag}`.
struct RoadTwinMarks {
    private(set) var all: [(index: String.Index, ch: Character)] = []

    init?<Text: StringProtocol>(_ text: Text) where Text.Index == String.Index {
        var quote: Character?
        var reference = false
        var braces = 0
        var inType = false
        var previous: Character?
        for index in text.indices {
            let ch = text[index]
            defer { previous = ch }
            if let q = quote {
                if ch == q { quote = nil }
            } else if reference {
                if ch == "}" { reference = false }
            } else if ch == "'" || ch == "\"" {
                quote = ch
            } else if ch == "{", previous == "$" {
                reference = true
            } else if inType {
                if ch == "]" {
                    all.append((index, ch))
                    inType = false
                }
            } else if ch == "{" {
                if braces == 0 { all.append((index, ch)) }
                braces += 1
            } else if ch == "}", braces > 0 {
                braces -= 1
                if braces == 0 { all.append((index, ch)) }
            } else if ch == "[", braces == 0 {
                all.append((index, ch))
                inType = true
            }
        }
        guard quote == nil, !inType else { return nil }
    }
}
