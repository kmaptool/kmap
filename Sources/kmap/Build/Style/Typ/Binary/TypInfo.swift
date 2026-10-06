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
    /// The code page its labels are written in, where the file says; nil where it does not.
    var codePage: Int?

    static let signature = Array("GARMIN TYP".utf8)
    private static let codePageOffset = 0x15
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
            Array(bytes[2..<(2 + signature.count)]) == signature
        else { return nil }

        let family = Int(bytes[familyIDOffset]) | (Int(bytes[familyIDOffset + 1]) << 8)
        let product = Int(bytes[productIDOffset]) | (Int(bytes[productIDOffset + 1]) << 8)
        guard family > 0 else { return nil }
        let page = Int(bytes[codePageOffset]) | (Int(bytes[codePageOffset + 1]) << 8)
        return TypInfo(
            url: url,
            familyID: family,
            productID: max(1, product),
            isBinary: true,
            codePage: page > 0 ? page : nil
        )
    }

    /// Past this a `.txt` is not a TYP source, and is not read whole to find that out.
    private static let largestSource: Int64 = 64 << 20

    private static func readText(_ url: URL) -> TypInfo? {
        guard FileTools.size(of: url) <= largestSource, let text = TypSource.text(of: url) else { return nil }
        var family: Int? = nil
        var product = 1
        var page: Int?
        // TextLines.of, not split: a CRLF file would be one line and no TYP at all.
        for line in TextLines.of(text).prefix(200) {
            guard let (key, noted) = TypSource.entry(of: line) else { continue }
            let value = noted.split(separator: ";").first.map(String.init) ?? ""
            switch key.uppercased() {
            // Numbers as mkgmap reads them: `FID=0x1234` too.
            case "FID": family = TypSource.decodedInteger(value)
            case "PRODUCTCODE": product = TypSource.decodedInteger(value) ?? 1
            case "CODEPAGE": page = TypSource.decodedInteger(value)
            default: break
            }
        }
        guard let family else { return nil }
        return TypInfo(url: url, familyID: family, productID: product, isBinary: false, codePage: page)
    }
}
