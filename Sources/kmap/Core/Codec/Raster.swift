import CStbImage
import Foundation

/// Decoding a picture and resampling it onto another grid.
///
/// Both are done here rather than through a system framework, so every platform produces
/// the same pixels. `IconImport` falls back to the system decoder only for formats stb
/// declines.
enum Raster {

    /// Straight (not premultiplied) 8-bit RGBA, row-major, top row first.
    struct Bitmap: Equatable {
        let width: Int
        let height: Int
        /// `width * height * 4` bytes.
        var rgba: [UInt8]

        var isEmpty: Bool { width <= 0 || height <= 0 }

        init(width: Int, height: Int, rgba: [UInt8]) {
            self.width = width
            self.height = height
            self.rgba = rgba
        }

        init(width: Int, height: Int) {
            self.init(width: width, height: height,
                      rgba: [UInt8](repeating: 0, count: max(0, width * height * 4)))
        }

        subscript(x: Int, y: Int) -> (r: UInt8, g: UInt8, b: UInt8, a: UInt8) {
            let i = (y * width + x) * 4
            return (rgba[i], rgba[i + 1], rgba[i + 2], rgba[i + 3])
        }
    }

    // MARK: Reading

    /// The largest picture that will be decoded, in pixels. Checked against the header
    /// before anything is allocated.
    static let maximumPixels = 64_000_000

    /// Decodes PNG, JPEG, BMP or GIF. Nil for anything else.
    static func decode(_ bytes: [UInt8]) -> Bitmap? {
        guard !bytes.isEmpty else { return nil }
        var width: Int32 = 0, height: Int32 = 0, channels: Int32 = 0

        // `stbi_info` reads the header only, so an oversized declared size costs no
        // allocation.
        let describable = bytes.withUnsafeBufferPointer { buffer in
            stbi_info_from_memory(buffer.baseAddress, Int32(buffer.count),
                                  &width, &height, &channels) == 1
        }
        guard describable, width > 0, height > 0,
              Int(width) * Int(height) <= maximumPixels else { return nil }

        // 4 requests RGBA whatever the file holds: greyscale, palette, no alpha.
        guard let pixels = bytes.withUnsafeBufferPointer({ buffer in
            stbi_load_from_memory(buffer.baseAddress, Int32(buffer.count),
                                  &width, &height, &channels, 4)
        }) else { return nil }
        defer { stbi_image_free(pixels) }

        let count = Int(width) * Int(height) * 4
        return Bitmap(width: Int(width), height: Int(height),
                      rgba: Array(UnsafeBufferPointer(start: pixels, count: count)))
    }

    static func decode(contentsOf url: URL) -> Bitmap? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return decode(Array(data))
    }

    /// Returns the dimensions declared in the header, without decoding.
    static func dimensions(_ bytes: [UInt8]) -> (width: Int, height: Int)? {
        var width: Int32 = 0, height: Int32 = 0, channels: Int32 = 0
        let ok = bytes.withUnsafeBufferPointer { buffer in
            stbi_info_from_memory(buffer.baseAddress, Int32(buffer.count),
                                  &width, &height, &channels) == 1
        }
        guard ok, width > 0, height > 0 else { return nil }
        return (Int(width), Int(height))
    }

    // MARK: Resampling

    /// Resamples `source` onto a `width` × `height` grid, returning it unchanged when it
    /// is already that size.
    ///
    /// Shrinking axes are area-averaged and growing axes bilinear. Samples are
    /// premultiplied across the filter, so transparent pixels do not bleed into edges.
    static func resampled(_ source: Bitmap, width: Int, height: Int) -> Bitmap {
        guard !source.isEmpty, width > 0, height > 0 else { return Bitmap(width: 0, height: 0) }
        if source.width == width && source.height == height { return source }

        // Premultiplied, in Float so a sum over many samples cannot wrap.
        var premultiplied = [Float](repeating: 0, count: source.width * source.height * 4)
        for i in stride(from: 0, to: premultiplied.count, by: 4) {
            let alpha = Float(source.rgba[i + 3]) / 255
            premultiplied[i] = Float(source.rgba[i]) * alpha
            premultiplied[i + 1] = Float(source.rgba[i + 1]) * alpha
            premultiplied[i + 2] = Float(source.rgba[i + 2]) * alpha
            premultiplied[i + 3] = Float(source.rgba[i + 3])
        }

        // The filter is chosen per axis, since one axis may grow while the other
        // shrinks. A disagreeing pair is resampled one axis at a time; at a scale of 1
        // both filters are exact, so the untouched axis passes through unchanged.
        let from = (source.width, source.height)
        let narrowing = width <= source.width, shortening = height <= source.height
        let filtered: [Float]
        switch (narrowing, shortening) {
        case (true, true):
            filtered = areaAverage(premultiplied, from: from, to: (width, height))
        case (false, false):
            filtered = bilinear(premultiplied, from: from, to: (width, height))
        case (true, false):
            // Narrow first, so the average runs over the taller source.
            let narrowed = areaAverage(premultiplied, from: from, to: (width, source.height))
            filtered = bilinear(narrowed, from: (width, source.height), to: (width, height))
        case (false, true):
            let shortened = areaAverage(premultiplied, from: from, to: (source.width, height))
            filtered = bilinear(shortened, from: (source.width, height), to: (width, height))
        }

        var out = Bitmap(width: width, height: height)
        for i in stride(from: 0, to: filtered.count, by: 4) {
            let alpha = filtered[i + 3]
            let scale = alpha > 0 ? 255 / alpha : 0
            out.rgba[i] = clamped(filtered[i] * scale)
            out.rgba[i + 1] = clamped(filtered[i + 1] * scale)
            out.rgba[i + 2] = clamped(filtered[i + 2] * scale)
            out.rgba[i + 3] = clamped(alpha)
        }
        return out
    }

    static func resampled(_ source: Bitmap, toSquare size: Int) -> Bitmap {
        resampled(source, width: size, height: size)
    }

    // MARK: The two filters

    /// Each destination pixel is the mean of the source region it covers, weighted by
    /// how much of each edge pixel falls inside it.
    private static func areaAverage(_ source: [Float], from: (Int, Int), to: (Int, Int)) -> [Float] {
        let (sw, sh) = from, (dw, dh) = to
        var out = [Float](repeating: 0, count: dw * dh * 4)
        let xScale = Float(sw) / Float(dw)
        let yScale = Float(sh) / Float(dh)

        for dy in 0..<dh {
            let top = Float(dy) * yScale
            let bottom = min(Float(dy + 1) * yScale, Float(sh))
            let firstRow = Int(top)
            let lastRow = min(Int(bottom.rounded(.up)) - 1, sh - 1)

            for dx in 0..<dw {
                let left = Float(dx) * xScale
                let right = min(Float(dx + 1) * xScale, Float(sw))
                let firstColumn = Int(left)
                let lastColumn = min(Int(right.rounded(.up)) - 1, sw - 1)

                var sums: (Float, Float, Float, Float) = (0, 0, 0, 0)
                var weight: Float = 0
                for sy in firstRow...max(firstRow, lastRow) {
                    // How much of this row lies inside the destination pixel; a fraction
                    // at the two ends.
                    let rowWeight = min(bottom, Float(sy + 1)) - max(top, Float(sy))
                    guard rowWeight > 0 else { continue }
                    for sx in firstColumn...max(firstColumn, lastColumn) {
                        let columnWeight = min(right, Float(sx + 1)) - max(left, Float(sx))
                        guard columnWeight > 0 else { continue }
                        let w = rowWeight * columnWeight
                        let i = (sy * sw + sx) * 4
                        sums.0 += source[i] * w
                        sums.1 += source[i + 1] * w
                        sums.2 += source[i + 2] * w
                        sums.3 += source[i + 3] * w
                        weight += w
                    }
                }
                let j = (dy * dw + dx) * 4
                guard weight > 0 else { continue }
                out[j] = sums.0 / weight
                out[j + 1] = sums.1 / weight
                out[j + 2] = sums.2 / weight
                out[j + 3] = sums.3 / weight
            }
        }
        return out
    }

    /// Each destination pixel is interpolated between the four source pixels around the
    /// point it lands on.
    private static func bilinear(_ source: [Float], from: (Int, Int), to: (Int, Int)) -> [Float] {
        let (sw, sh) = from, (dw, dh) = to
        var out = [Float](repeating: 0, count: dw * dh * 4)
        // Sampled at pixel centres, so source corners land on result corners.
        let xScale = Float(sw) / Float(dw)
        let yScale = Float(sh) / Float(dh)

        for dy in 0..<dh {
            let sourceY = max(0, (Float(dy) + 0.5) * yScale - 0.5)
            let y0 = min(Int(sourceY), sh - 1)
            let y1 = min(y0 + 1, sh - 1)
            let fy = sourceY - Float(y0)

            for dx in 0..<dw {
                let sourceX = max(0, (Float(dx) + 0.5) * xScale - 0.5)
                let x0 = min(Int(sourceX), sw - 1)
                let x1 = min(x0 + 1, sw - 1)
                let fx = sourceX - Float(x0)

                let j = (dy * dw + dx) * 4
                for channel in 0..<4 {
                    let topLeft = source[(y0 * sw + x0) * 4 + channel]
                    let topRight = source[(y0 * sw + x1) * 4 + channel]
                    let bottomLeft = source[(y1 * sw + x0) * 4 + channel]
                    let bottomRight = source[(y1 * sw + x1) * 4 + channel]
                    let top = topLeft + (topRight - topLeft) * fx
                    let bottom = bottomLeft + (bottomRight - bottomLeft) * fx
                    out[j + channel] = top + (bottom - top) * fy
                }
            }
        }
        return out
    }

    private static func clamped(_ value: Float) -> UInt8 {
        UInt8(max(0, min(255, value.rounded())))
    }
}
