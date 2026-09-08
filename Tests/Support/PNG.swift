import Foundation
@testable import kmap

/// A PNG writer, for making test pictures. It shares no code with the decoder under
/// test, so a fixture that reads back wrong is a real disagreement.
///
/// The simplest PNG the format allows: 8-bit RGBA, no interlace, one IDAT, filter 0.
enum PNG {

    /// `width` × `height` straight RGBA, top row first.
    static func encode(width: Int, height: Int, rgba: [UInt8]) -> Data {
        precondition(rgba.count == width * height * 4)

        var raw = [UInt8]()
        raw.reserveCapacity(height * (1 + width * 4))
        for row in 0..<height {
            raw.append(0)                                  // filter: none
            raw.append(contentsOf: rgba[(row * width * 4)..<((row + 1) * width * 4)])
        }

        var header = [UInt8]()
        header.append(contentsOf: be32(UInt32(width)))
        header.append(contentsOf: be32(UInt32(height)))
        header.append(contentsOf: [8, 6, 0, 0, 0])         // 8 bits, truecolour + alpha

        var out = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        out.append(chunk("IHDR", header))
        out.append(chunk("IDAT", Zlib.deflate(raw) ?? []))
        out.append(chunk("IEND", []))
        return out
    }

    /// A square with a red block in the top-left corner and a blue one in the
    /// bottom-right, everything else clear. Asymmetric, so a picture that arrives
    /// mirrored or upside down does not read as correct.
    static func corners(size: Int, block: Int) -> Data {
        var rgba = [UInt8](repeating: 0, count: size * size * 4)
        func paint(_ x: Int, _ y: Int, _ colour: (UInt8, UInt8, UInt8)) {
            let i = (y * size + x) * 4
            rgba[i] = colour.0; rgba[i + 1] = colour.1; rgba[i + 2] = colour.2; rgba[i + 3] = 255
        }
        for y in 0..<min(block, size) {
            for x in 0..<min(block, size) { paint(x, y, (255, 0, 0)) }
        }
        for y in max(0, size - block)..<size {
            for x in max(0, size - block)..<size { paint(x, y, (0, 0, 255)) }
        }
        return encode(width: size, height: size, rgba: rgba)
    }

    // MARK: Chunks

    private static func chunk(_ type: String, _ payload: [UInt8]) -> Data {
        var body = Array(type.utf8)
        body.append(contentsOf: payload)
        var out = Data(be32(UInt32(payload.count)))
        out.append(contentsOf: body)
        out.append(contentsOf: be32(crc32(body)))
        return out
    }

    private static func be32(_ value: UInt32) -> [UInt8] {
        [UInt8(value >> 24 & 0xFF), UInt8(value >> 16 & 0xFF),
         UInt8(value >> 8 & 0xFF), UInt8(value & 0xFF)]
    }

    /// CRC-32 as PNG specifies it, written out rather than taken from zlib.
    private static func crc32(_ bytes: [UInt8]) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in bytes {
            crc ^= UInt32(byte)
            for _ in 0..<8 {
                crc = (crc & 1) != 0 ? (crc >> 1) ^ 0xEDB8_8320 : crc >> 1
            }
        }
        return crc ^ 0xFFFF_FFFF
    }
}
