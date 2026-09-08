import Foundation

/// Reads the identifying header of a Garmin TYP file.
///
/// A binary TYP starts with a 2-byte header length, then the literal "GARMIN TYP".
/// The family id and product id sit at fixed offsets and must match the `--family-id` /
/// `--product-id` mkgmap is invoked with, otherwise the device ignores the TYP entirely.
struct TypInfo {
    let url: URL
    let familyID: Int
    let productID: Int
    let isBinary: Bool

    static let signature = Array("GARMIN TYP".utf8)
    private static let familyIDOffset = 0x2F
    private static let productIDOffset = 0x31

    /// Parses a `.typ` (binary) or `.txt` (mkgmap TYP source) file.
    static func read(_ url: URL) -> TypInfo? {
        let ext = url.pathExtension.lowercased()
        if ext == "txt" { return readText(url) }
        return readBinary(url)
    }

    private static func readBinary(_ url: URL) -> TypInfo? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let head = try? handle.read(upToCount: 0x40), head.count >= productIDOffset + 2 else {
            return nil
        }
        let bytes = [UInt8](head)
        // The signature follows the 2-byte header length.
        guard bytes.count > 2 + signature.count,
              Array(bytes[2..<(2 + signature.count)]) == signature else { return nil }

        let family = Int(bytes[familyIDOffset]) | (Int(bytes[familyIDOffset + 1]) << 8)
        let product = Int(bytes[productIDOffset]) | (Int(bytes[productIDOffset + 1]) << 8)
        guard family > 0 else { return nil }
        return TypInfo(url: url, familyID: family, productID: max(1, product), isBinary: true)
    }

    private static func readText(_ url: URL) -> TypInfo? {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        var family: Int? = nil
        var product = 1
        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: true).prefix(200) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard let eq = line.firstIndex(of: "=") else { continue }
            let key = line[line.startIndex..<eq].trimmingCharacters(in: .whitespaces).uppercased()
            let value = line[line.index(after: eq)...]
                .trimmingCharacters(in: .whitespaces)
                .split(separator: ";").first.map(String.init) ?? ""
            switch key {
            case "FID": family = Int(value.trimmingCharacters(in: .whitespaces))
            case "PRODUCTCODE": product = Int(value.trimmingCharacters(in: .whitespaces)) ?? 1
            default: break
            }
        }
        guard let family else { return nil }
        return TypInfo(url: url, familyID: family, productID: product, isBinary: false)
    }
}
