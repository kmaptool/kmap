import Foundation

/// Splits text into lines identically on every platform and for every line ending.
///
/// Swift treats `\r\n` as one `Character`, so `split(separator:)` and
/// `components(separatedBy:)` disagree with each other and across platforms on CRLF
/// input. These functions work over unicode scalars, which is consistent.
enum Lines {

    /// Returns `text` as lines with the ending removed; CRLF, LF and a lone CR all end a
    /// line. A trailing newline produces no empty last line.
    static func of(_ text: String) -> [String] {
        var out: [String] = []
        out.reserveCapacity(text.unicodeScalars.count / 32 + 1)
        var current = String.UnicodeScalarView()
        var sawCarriageReturn = false

        func flush() {
            if sawCarriageReturn { current.removeLast() }
            out.append(String(current))
            current = String.UnicodeScalarView()
            sawCarriageReturn = false
        }

        for scalar in text.unicodeScalars {
            switch scalar {
            case "\n":
                flush()
            case "\r":
                // A lone carriage return also ends a line, so mixed endings lose none.
                if sawCarriageReturn { flush() }
                current.append(scalar)
                sawCarriageReturn = true
            default:
                if sawCarriageReturn { flush(); }
                current.append(scalar)
            }
        }
        if !current.isEmpty { flush() }
        return out
    }

    /// Returns `of(text)` plus the empty line a trailing newline implies.
    ///
    /// Required by callers that rejoin the lines and must preserve a trailing newline;
    /// read-only parsers use `of`.
    static func keepingTrailingBlank(_ text: String) -> [String] {
        var out = of(text)
        if text.unicodeScalars.last == "\n" || text.unicodeScalars.last == "\r" {
            out.append("")
        }
        return out
    }
}
