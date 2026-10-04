import Foundation

/// FABDEM v1.2 (University of Bristol): Copernicus GLO-30 without forests and
/// buildings, 60S to 80N. CC BY-NC-SA 4.0.
///
/// From the Hugging Face mirror, a COG per degree in 10 deg folders. Float32, deflate,
/// predictor 2, PixelIsPoint.
struct FABDEM: DEMTileSource {
    static let v12 = FABDEM()

    let sourceID = "fabdem1"
    let directoryName = "FAB1"
    let nodes = 3601
    let tifCacheName = "fabdem-tif"
    let label = "FABDEM"
    let family = "FABDEM"
    /// Its licence also requires the Copernicus attribution.
    let credits = ["FABDEM: University of Bristol, CC BY-NC-SA 4.0", CopernicusDEM.credit]

    static let root = "https://huggingface.co/buckets/links-ads/fabdem/resolve"

    func tileURL(lat: Int, lon: Int) -> URL? {
        let name = HGTName.of(lat: lat, lon: lon)
        return URL(string: "\(Self.root)/tiles/\(Self.folder(lat: lat, lon: lon))_FABDEM_V1-2/\(name)_FABDEM_V1-2.tif")
    }

    /// The 10 deg folder a cell sits in, named by its corners: N40E040-N50E050. The east
    /// corner of the last column is spelled W180, as the archive spells it.
    static func folder(lat: Int, lon: Int) -> String {
        let south = Int((Double(lat) / 10).rounded(.down)) * 10
        let west = Int((Double(lon) / 10).rounded(.down)) * 10
        let east = west + 10 == 180 ? -180 : west + 10
        return "\(HGTName.of(lat: south, lon: west))-\(HGTName.of(lat: south + 10, lon: east))"
    }

    /// The archive's GeoJSON index, 9 MB.
    var tileListURL: URL? { URL(string: "\(Self.root)/FABDEM_v1-2_tiles.geojson") }
    var tileListCacheName: String { "fabdem-tiles.geojson" }

    /// Cell names from the tiles' file names. The padded `file_name` spelling (N079W106)
    /// fails the name check.
    func parseTileList(_ text: String) -> Set<String> {
        var out = Set<String>()
        let suffix = Array("_FABDEM_V1-2.tif".utf8)
        var copy = text
        copy.withUTF8 { bytes in
            // Bytes, not Foundation's search, which on Linux copies the rest of the string per match.
            var i = 7
            while i + suffix.count <= bytes.count {
                if bytes[i] == suffix[0], suffix.indices.allSatisfy({ bytes[i + $0] == suffix[$0] }) {
                    let name = String(decoding: bytes[(i - 7)..<i], as: UTF8.self)
                    if HGTName.corner(of: name).map({ HGTName.of(lat: $0.lat, lon: $0.lon) }) == name {
                        out.insert(name)
                    }
                    i += suffix.count
                } else {
                    i += 1
                }
            }
        }
        return out
    }

    /// Only 404: Hugging Face answers 403 for a refusal, not for a missing file.
    func isAbsent(_ error: Error) -> Bool {
        if case DownloadError.badStatus(let code) = error { return code == 404 }
        return false
    }
}
