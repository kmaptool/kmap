import Foundation

// Apple's own decoders, kept for the formats stb does not read - TIFF and HEIC through
// ImageIO, SVG through AppKit. They are asked second, and only where they exist.
#if canImport(ImageIO)
import CoreGraphics
import ImageIO
#endif
#if canImport(AppKit)
import AppKit
#endif

/// Turns a picture on disk into a TYP drawing.
///
/// A TYP icon is a palette of at most 256 colours with one transparent slot and no alpha,
/// on a small square grid. The result reports how far the picture was scaled, how many
/// colours it lost, and how many pixels had to be forced solid or clear.
enum IconImport {
    /// The palette ceiling: a point image indexes its palette with at most eight bits. One
    /// slot goes to transparency wherever the source has any.
    static let maximumColours = 256

    /// Below this, a pixel is treated as clear; at or above it, as solid. A TYP has one
    /// transparent colour and no alpha, so an antialiased edge has to fall one way.
    private static let alphaThreshold = 128

    // MARK: Loading

    /// Reads a picture and returns it as a TYP drawing at `size` x `size`.
    ///
    /// - Parameter size: the grid to produce. Nothing is cropped; a non-square source is
    ///   stretched into the square.
    static func load(_ url: URL, size: Int) throws -> Result {
        guard FileTools.exists(url) else { throw ImportError.notFound(Paths.display(url)) }
        guard size > 0, size <= 255 else { throw ImportError.empty }

        let (source, sourceSize) = try rasterise(url, into: size)
        guard !source.isEmpty else { throw ImportError.empty }

        return quantise(source, size: size, sourceSize: sourceSize)
    }

    /// One pixel as it came off the image.
    private struct Pixel {
        let r: UInt8, g: UInt8, b: UInt8, a: UInt8
        var hex: String { String(format: "#%02X%02X%02X", r, g, b) }
    }

    /// Draws the file into a `size` x `size` RGBA buffer, and reports the file's own size.
    /// A non-square source is stretched into the square rather than letterboxed.
    private static func rasterise(_ url: URL, into size: Int) throws -> ([Pixel], (Int, Int)) {
        guard let read = decode(url, at: size) else {
            throw ImportError.unreadable(url.lastPathComponent)
        }
        let image = read.bitmap
        // The file's own nominal size, not the bitmap in hand: the scaling warning is
        // about the file.
        let sourceSize = read.nominal
        let grid = Raster.resampled(image, toSquare: size)
        guard !grid.isEmpty else { throw ImportError.empty }

        var pixels: [Pixel] = []
        pixels.reserveCapacity(size * size)
        for index in stride(from: 0, to: grid.rgba.count, by: 4) {
            pixels.append(
                Pixel(
                    r: grid.rgba[index],
                    g: grid.rgba[index + 1],
                    b: grid.rgba[index + 2],
                    a: grid.rgba[index + 3]
                )
            )
        }
        return (pixels, sourceSize)
    }

    /// Reads the file, by whichever route can read it: stb for PNG, JPEG, BMP and GIF on
    /// every platform, then ImageIO for TIFF and the camera formats and AppKit for SVG,
    /// where those exist.
    ///
    /// - Parameter size: the grid this is headed for. A drawing with no pixels of its own
    ///   is rendered straight onto it; a raster is read at its own size and resampled.
    private static func decode(
        _ url: URL,
        at size: Int
    ) -> (
        bitmap: Raster.Bitmap,
        nominal: (Int, Int)
    )? {
        if let bitmap = Raster.decode(contentsOf: url) {
            return (bitmap, (bitmap.width, bitmap.height))
        }
        #if canImport(ImageIO)
        if let source = CGImageSourceCreateWithURL(url as CFURL, nil),
            let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
            let bitmap = drawn(image, width: image.width, height: image.height)
        {
            return (bitmap, (image.width, image.height))
        }
        #endif
        #if canImport(AppKit)
        if let image = NSImage(contentsOf: url), image.size.width > 0 {
            let nominal = (Int(image.size.width.rounded()), Int(image.size.height.rounded()))
            // A representation made of pixels is read at its own size; anything else is a
            // drawing, and a drawing is rendered at the size it is wanted at.
            let hasPixels = image.representations.contains { $0 is NSBitmapImageRep }
            let wide = hasPixels ? nominal.0 : size
            let high = hasPixels ? nominal.1 : size
            let bitmap = drawn(width: wide, height: high) { context in
                let graphics = NSGraphicsContext(cgContext: context, flipped: false)
                NSGraphicsContext.saveGraphicsState()
                NSGraphicsContext.current = graphics
                // Antialiased here and only here: this is the one path that turns a
                // drawing into pixels.
                context.setShouldAntialias(!hasPixels)
                context.interpolationQuality = hasPixels ? .none : .high
                image.draw(in: NSRect(x: 0, y: 0, width: wide, height: high))
                NSGraphicsContext.restoreGraphicsState()
            }
            if let bitmap { return (bitmap, nominal) }
        }
        #endif
        return nil
    }

    #if canImport(ImageIO)
    /// An Apple image at its own size, as straight RGBA. Native size, so the resampling
    /// happens in `Raster`; sRGB rather than the device space, which colour-manages the
    /// pixels on the way in and shifts the colours a palette is matched against.
    private static func drawn(_ image: CGImage, width: Int, height: Int) -> Raster.Bitmap? {
        drawn(width: width, height: height) { context in
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
    }

    private static func drawn(
        width: Int,
        height: Int,
        _ body: (CGContext) -> Void
    ) -> Raster.Bitmap? {
        guard width > 0, height > 0, width * height <= Raster.maximumPixels else { return nil }
        let space = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        var buffer = [UInt8](repeating: 0, count: width * height * 4)
        let drew = buffer.withUnsafeMutableBytes { raw -> Bool in
            guard
                let context = CGContext(
                    data: raw.baseAddress,
                    width: width,
                    height: height,
                    bitsPerComponent: 8,
                    bytesPerRow: width * 4,
                    space: space,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                )
            else { return false }
            context.interpolationQuality = .none
            context.setShouldAntialias(false)
            body(context)
            return true
        }
        guard drew else { return nil }
        // Core Graphics hands back premultiplied alpha; `Raster` works in straight.
        for i in stride(from: 0, to: buffer.count, by: 4) {
            let a = buffer[i + 3]
            guard a > 0, a < 255 else { continue }
            for channel in 0..<3 {
                buffer[i + channel] = UInt8(min(255, Int(buffer[i + channel]) * 255 / Int(a)))
            }
        }
        return Raster.Bitmap(width: width, height: height, rgba: buffer)
    }
    #endif

    // MARK: Palette

    /// Turns straight RGBA into a palette and pixel rows. Colours are taken by how much of
    /// the picture they cover, and anything past the ceiling is mapped to the nearest kept.
    private static func quantise(
        _ pixels: [Pixel],
        size: Int,
        sourceSize: (Int, Int)
    ) -> Result {
        var soft = 0
        var tally: [String: Int] = [:]

        for pixel in pixels {
            if pixel.a > 0, pixel.a < 255 { soft += 1 }
            guard pixel.a >= UInt8(alphaThreshold) else { continue }
            tally[pixel.hex, default: 0] += 1
        }

        let hasTransparency = pixels.contains { $0.a < UInt8(alphaThreshold) }
        let room = hasTransparency ? maximumColours - 1 : maximumColours
        // Ties broken by the colour itself, so the same picture imports the same way twice.
        let ordered = tally.sorted { ($0.value, $1.key) > ($1.value, $0.key) }
        let kept = ordered.prefix(room).map(\.key)

        var indexOf: [String: Int] = [:]
        for (index, colour) in kept.enumerated() { indexOf[colour] = index }

        // Anything that did not make the cut goes to the nearest that did.
        var mapped: [String: Int] = indexOf
        for (colour, _) in ordered.dropFirst(room) {
            mapped[colour] = nearest(colour, among: kept, indexOf: indexOf)
        }

        // One character per pixel while the alphabet lasts, two once it does not: a key
        // repeated because the index wrapped would give two colours the same name.
        let clearIndex = kept.count
        let count = kept.count + (hasTransparency ? 1 : 0)
        let keyWidth = count <= alphabet.count ? 1 : 2

        var palette: [(key: String, colour: String?)] = []
        for (index, colour) in kept.enumerated() {
            palette.append((key: key(index, width: keyWidth), colour: colour))
        }
        if hasTransparency {
            palette.append((key: key(clearIndex, width: keyWidth), colour: nil))
        }

        var rows: [String] = []
        for y in 0..<size {
            var row = ""
            for x in 0..<size {
                let pixel = pixels[y * size + x]
                let index =
                    pixel.a >= UInt8(alphaThreshold)
                    ? (mapped[pixel.hex] ?? 0)
                    : clearIndex
                row += key(min(index, palette.count - 1), width: keyWidth)
            }
            rows.append(row)
        }

        let block = XpmBlock(
            width: size,
            height: size,
            declaredColours: palette.count,
            charsPerPixel: keyWidth,
            palette: palette,
            rows: rows
        )
        return Result(
            block: block,
            sourceWidth: sourceSize.0,
            sourceHeight: sourceSize.1,
            sourceColours: tally.count,
            paletteSize: palette.count,
            softEdgePixels: soft
        )
    }

    private static func nearest(
        _ colour: String,
        among kept: [String],
        indexOf: [String: Int]
    ) -> Int {
        guard let target = rgb(colour), !kept.isEmpty else { return 0 }
        var best = 0
        var bestDistance = Int.max
        for candidate in kept {
            guard let value = rgb(candidate) else { continue }
            let distance =
                (value.0 - target.0) * (value.0 - target.0)
                + (value.1 - target.1) * (value.1 - target.1)
                + (value.2 - target.2) * (value.2 - target.2)
            if distance < bestDistance {
                bestDistance = distance
                best = indexOf[candidate] ?? 0
            }
        }
        return best
    }

    private static func rgb(_ hex: String) -> (Int, Int, Int)? {
        var s = hex
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let value = Int(s, radix: 16) else { return nil }
        return ((value >> 16) & 0xFF, (value >> 8) & 0xFF, value & 0xFF)
    }

    /// Palette keys, one character each while the alphabet lasts and two past it.
    private static let alphabet = XpmBlock.keyAlphabet

    private static func key(_ index: Int, width: Int) -> String {
        XpmBlock.key(index, width: width)
    }
}
