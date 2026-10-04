import CVector
import Foundation

extension GeoTIFF {
    /// How 1 tile or strip holds its samples, and the way from its bytes to numbers.
    struct Block: Sendable {
        let width: Int
        let height: Int
        /// 2 or 4.
        let bytesPerSample: Int
        let sampleFormat: Int
        let predictor: Int
        let bigEndian: Bool

        var samples: Int { width * height }
        var bytes: Int { samples * bytesPerSample }

        private var isFloat32: Bool { bytesPerSample == 4 && sampleFormat == TIFF.SampleFormat.float }

        /// The block's samples from its `bytes` decompressed bytes, which are undone in
        /// place on the way.
        func floats(from raw: inout [UInt8]) -> [Float] {
            guard isFloat32 else {
                undoPredictor(&raw)
                return plainSamples(raw)
            }
            let count = samples, planes = predictor == TIFF.Predictor.floatingPoint
            return [Float](unsafeUninitializedCapacity: count) { out, filled in
                filled = count
                raw.withUnsafeMutableBufferPointer { raw in
                    guard let start = raw.baseAddress, let floats = out.baseAddress else { return }
                    if planes {
                        // The published DEM tiles are all this kind.
                        if !GeoTIFF.vectorFloatRows(start, width: width, rows: height, into: floats) {
                            GeoTIFF.floatRows(start, width: width, rows: height, into: floats)
                        }
                    } else {
                        GeoTIFF.wordRows(
                            start,
                            width: width,
                            rows: height,
                            bigEndian: bigEndian,
                            differenced: predictor == TIFF.Predictor.horizontal,
                            into: floats
                        )
                    }
                }
            }
        }

        /// Predictor 2 stores each sample as the difference from its left neighbour;
        /// predictor 3 does the same to the bytes, having first grouped a row's bytes by
        /// significance. Undoing 3 takes 2 passes: sum along the row bytewise, then
        /// regather each sample.
        private func undoPredictor(_ raw: inout [UInt8]) {
            let floating = predictor == TIFF.Predictor.floatingPoint
            guard floating || predictor == TIFF.Predictor.horizontal else { return }
            let stride = width * bytesPerSample
            raw.withUnsafeMutableBufferPointer { buffer in
                guard let start = buffer.baseAddress, stride > 0 else { return }
                let gathered = UnsafeMutablePointer<UInt8>.allocate(capacity: floating ? stride : 1)
                defer { gathered.deallocate() }
                for r in 0..<height {
                    let row = start + r * stride
                    if floating {
                        // Stored a plane at a time: every sample's first byte, then
                        // every second, and on.
                        var sum = row[0]
                        for i in 1..<stride {
                            sum &+= row[i]
                            row[i] = sum
                        }
                        for byte in 0..<bytesPerSample {
                            let plane = row + byte * width
                            for sample in 0..<width { gathered[sample * bytesPerSample + byte] = plane[sample] }
                        }
                        row.update(from: gathered, count: stride)
                    } else if bytesPerSample == 4 {
                        sumWords(UnsafeMutableRawPointer(row), as: UInt32.self)
                    } else {
                        sumWords(UnsafeMutableRawPointer(row), as: UInt16.self)
                    }
                }
            }
        }

        /// A row of integer samples in the file's byte order, each replaced by the sum
        /// of itself and all before it.
        private func sumWords<Word: FixedWidthInteger>(_ row: UnsafeMutableRawPointer, as: Word.Type) {
            let size = MemoryLayout<Word>.size
            var sum: Word = 0
            for k in 0..<width {
                let word = row.loadUnaligned(fromByteOffset: k * size, as: Word.self)
                sum &+= bigEndian ? Word(bigEndian: word) : Word(littleEndian: word)
                row.storeBytes(of: bigEndian ? sum.bigEndian : sum.littleEndian, toByteOffset: k * size, as: Word.self)
            }
        }

        /// The bytes as numbers. Predictor 3 leaves them most significant byte first
        /// whatever the file's byte order.
        private func plainSamples(_ raw: [UInt8]) -> [Float] {
            var out = [Float](repeating: 0, count: samples)
            let msbFirst = predictor == TIFF.Predictor.floatingPoint || bigEndian
            let isFloat = sampleFormat == TIFF.SampleFormat.float
            let isSigned = sampleFormat == TIFF.SampleFormat.signed
            raw.withUnsafeBytes { bytes in
                out.withUnsafeMutableBufferPointer { out in
                    // Each branch is a plain loop over 2 pointers, which the compiler vectorises.
                    if bytesPerSample == 4 {
                        for i in 0..<out.count {
                            let word = bytes.loadUnaligned(fromByteOffset: i * 4, as: UInt32.self)
                            let bits = msbFirst ? UInt32(bigEndian: word) : UInt32(littleEndian: word)
                            out[i] = isFloat ? Float(bitPattern: bits) : Float(Int32(bitPattern: bits))
                        }
                    } else {
                        for i in 0..<out.count {
                            let word = bytes.loadUnaligned(fromByteOffset: i * 2, as: UInt16.self)
                            let bits = msbFirst ? UInt16(bigEndian: word) : UInt16(littleEndian: word)
                            out[i] = isSigned ? Float(Int16(bitPattern: bits)) : Float(bits)
                        }
                    }
                }
            }
            return out
        }
    }

    // MARK: Rows of 32-bit floats

    /// Rows of 32-bit float words to numbers, each row summed first under predictor 2
    /// (as integers, as libtiff does).
    static func wordRows(
        _ raw: UnsafeMutablePointer<UInt8>,
        width: Int,
        rows: Int,
        bigEndian: Bool,
        differenced: Bool,
        into floats: UnsafeMutablePointer<Float>
    ) {
        if !bigEndian, kmap_word_rows(raw, width, rows, differenced ? 1 : 0, floats) != 0 { return }
        plainWordRows(raw, width: width, rows: rows, bigEndian: bigEndian, differenced: differenced, into: floats)
    }

    /// The same a word at a time: no vector code, big-endian files, and the tests.
    static func plainWordRows(
        _ raw: UnsafeMutablePointer<UInt8>,
        width: Int,
        rows: Int,
        bigEndian: Bool,
        differenced: Bool,
        into floats: UnsafeMutablePointer<Float>
    ) {
        let words = UnsafeRawPointer(raw)
        for r in 0..<rows {
            let line = floats + r * width
            var previous: UInt32 = 0
            for k in 0..<width {
                let word = words.loadUnaligned(fromByteOffset: (r * width + k) * 4, as: UInt32.self)
                var value = bigEndian ? UInt32(bigEndian: word) : UInt32(littleEndian: word)
                if differenced {
                    value &+= previous
                    previous = value
                }
                line[k] = Float(bitPattern: value)
            }
        }
    }

    /// Rows under predictor 3 to numbers, 16 bytes at a time: each row is 4 planes of
    /// bytes, most significant first, differenced as 1 run. False, having done nothing,
    /// in a build with no vector code.
    static func vectorFloatRows(
        _ start: UnsafeMutablePointer<UInt8>,
        width: Int,
        rows: Int,
        into floats: UnsafeMutablePointer<Float>
    ) -> Bool {
        kmap_float_rows(start, width, rows, floats) != 0
    }

    /// The same a byte at a time: no vector code, and the tests.
    static func floatRows(
        _ start: UnsafeMutablePointer<UInt8>,
        width: Int,
        rows: Int,
        into floats: UnsafeMutablePointer<Float>
    ) {
        let stride = width * 4
        guard stride > 0 else { return }
        for r in 0..<rows {
            let row = start + r * stride
            var sum = row[0]
            for i in 1..<stride {
                sum &+= row[i]
                row[i] = sum
            }
            let p0 = row, p1 = row + width, p2 = row + 2 * width, p3 = row + 3 * width
            let line = floats + r * width
            for s in 0..<width {
                let bits = UInt32(p0[s]) << 24 | UInt32(p1[s]) << 16 | UInt32(p2[s]) << 8 | UInt32(p3[s])
                line[s] = Float(bitPattern: bits)
            }
        }
    }
}
