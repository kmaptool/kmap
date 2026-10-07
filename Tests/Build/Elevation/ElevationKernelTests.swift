import XCTest

@testable import kmap

/// The vector loops behind the elevation rows held against the plain ones, at every tier
/// this machine has, at lengths that end a vector exactly, fall short of one and run past
/// several, and with the values rounding and holes make awkward.
final class ElevationKernelTests: XCTestCase {
    private let lengths = [0, 1, 3, 4, 5, 7, 8, 9, 15, 16, 17, 31, 32, 33, 100, 3601]

    /// Heights a rounding or a mask can get wrong, and random ones around them.
    private func heights(_ count: Int, random: inout SplitMix64) -> [Double] {
        let awkward: [Double] = [
            0.5, -0.5, 1.5, -2.5, 0.49999999999999994, -0.49999999999999994, 2.4999, -2.5001,
            32767.4, 32767.5, 40000, -32768.5, -40000, .nan, .infinity, -.infinity, 0, -0.0, 3.4e38,
            Double(Float(0.5).nextDown), Double.leastNormalMagnitude / 2, -Double.leastNormalMagnitude / 2, 3e9, -3e9,
            1e300
        ]
        return (0..<count).map { i in
            i % 3 == 0 ? awkward[(i / 3) % awkward.count] : Double.random(in: -500...9000, using: &random)
        }
    }

    func testDoubleHeightsAreStoredTheSameWayAVectorAtATime() {
        var random = SplitMix64(state: 20_261_003)
        for count in lengths {
            let input = heights(count, random: &random)
            var plain = [UInt8](repeating: 0xEE, count: count * 2)
            let plainStored = plain.withUnsafeMutableBufferPointer { out in
                HGTConversion.plainStoreHeights(count: count, into: out.baseAddress!) { input[$0] }
            }
            VectorTiers.each { tier in
                var vector = [UInt8](repeating: 0xEE, count: count * 2)
                let stored = input.withUnsafeBufferPointer { heights in
                    vector.withUnsafeMutableBufferPointer { out in
                        HGTConversion.storeHeights(heights.baseAddress!, count: count, into: out.baseAddress!)
                    }
                }
                XCTAssertEqual(stored, plainStored, "count \(count), tier \(tier)")
                XCTAssertEqual(vector, plain, "count \(count), tier \(tier)")
            }
        }
    }

    func testFloatHeightsAreStoredTheSameWayAVectorAtATimeWithTheirHoles() {
        var random = SplitMix64(state: 20_261_004)
        for count in lengths {
            for nodata in [Float.greatestFiniteMagnitude, .nan, 0, -0.0, -32768, nil] as [Float?] {
                // Holes every 5th place, so each lane of every vector meets one.
                var input = heights(count, random: &random).map(Float.init)
                if let nodata { for i in stride(from: 2, to: count, by: 5) { input[i] = nodata } }
                var plain = [UInt8](repeating: 0xEE, count: count * 2)
                let plainStored = plain.withUnsafeMutableBufferPointer { out in
                    HGTConversion.plainStoreHeights(count: count, into: out.baseAddress!) { i in
                        input[i] == nodata ? nil : Double(input[i])
                    }
                }
                VectorTiers.each { tier in
                    var vector = [UInt8](repeating: 0xEE, count: count * 2)
                    let stored = input.withUnsafeBufferPointer { heights in
                        vector.withUnsafeMutableBufferPointer { out in
                            HGTConversion.storeHeights(
                                heights.baseAddress!,
                                count: count,
                                nodata: nodata,
                                into: out.baseAddress!
                            )
                        }
                    }
                    XCTAssertEqual(
                        stored,
                        plainStored,
                        "count \(count), tier \(tier), nodata \(String(describing: nodata))"
                    )
                    XCTAssertEqual(vector, plain, "count \(count), tier \(tier), nodata \(String(describing: nodata))")
                }
            }
        }
    }

    func testTheWordPredictorIsUndoneTheSameWayAVectorAtATime() {
        var random = SplitMix64(state: 20_261_005)
        for width in lengths where width > 0 {
            let rows = 3
            let raw = (0..<(width * 4 * rows)).map { _ in UInt8.random(in: 0...255, using: &random) }
            for differenced in [true, false] {
                var plainBytes = raw
                var plain = [Float](repeating: 0, count: width * rows)
                plainBytes.withUnsafeMutableBufferPointer { bytes in
                    plain.withUnsafeMutableBufferPointer {
                        GeoTIFF.plainWordRows(
                            bytes.baseAddress!,
                            width: width,
                            rows: rows,
                            bigEndian: false,
                            differenced: differenced,
                            into: $0.baseAddress!
                        )
                    }
                }
                VectorTiers.each { tier in
                    var bytes = raw
                    var vector = [Float](repeating: 0, count: width * rows)
                    bytes.withUnsafeMutableBufferPointer { bytes in
                        vector.withUnsafeMutableBufferPointer {
                            GeoTIFF.wordRows(
                                bytes.baseAddress!,
                                width: width,
                                rows: rows,
                                bigEndian: false,
                                differenced: differenced,
                                into: $0.baseAddress!
                            )
                        }
                    }
                    XCTAssertEqual(vector.map(\.bitPattern), plain.map(\.bitPattern), "width \(width), tier \(tier)")
                    XCTAssertEqual(bytes, raw, "the input is left as it was")
                }
            }
        }
    }
}
