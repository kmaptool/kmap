import Foundation

/// Paths of local maps the functional tests read, with the results they must produce.
/// Located by `KMAP_TEST_MAPS`, else `~/.kmap/test-maps.json`; the tests skip when the
/// file is absent.
///
/// ```json
/// { "suggestion": [ { "path": "…", "first": "region-id", "never": ["region-id"] } ],
///   "reader":     [ { "path": "…", "ground": [minLat, minLon, maxLat, maxLon],
///                     "elements": 0, "vertices": 0, "md5": "…" } ] }
/// ```
struct LocalTestMaps: Decodable {
    /// One map and the region suggestion it must produce.
    struct Suggestion: Decodable {
        let path: String
        /// The region that must be offered first. Empty where any answer will do and
        /// only `never` is being tested.
        let first: String
        /// Regions that must not be offered at all.
        let never: [String]
    }

    /// One map, a ground to read, and the dump that must come out of it.
    struct Reader: Decodable {
        let path: String
        /// minLat, minLon, maxLat, maxLon, in degrees.
        let ground: [Double]
        let elements: Int
        let vertices: Int
        /// MD5 of the dump in `ElementDumper.write`'s form.
        let md5: String
    }

    /// One compiled TYP and what reading it must produce.
    struct Typ: Decodable {
        struct Label: Decodable {
            let code: Int
            let language: Int
            let text: String
        }
        struct Image: Decodable {
            let code: Int
            let width: Int
            let height: Int
            let palette: Int
        }
        struct Line: Decodable {
            let code: Int
            let colours: [String]
            let lineWidth: Int
            let borderWidth: Int
        }

        let path: String
        let familyID: Int
        let codePage: Int
        let polygons: Int
        let lines: Int
        let points: Int
        /// Elements read exactly, and elements in all — they differ where a file holds
        /// something the reader keeps but cannot decode.
        let exact: Int
        let all: Int
        let inexactCodes: [Int]
        let labels: [Label]
        let image: Image?
        let line: Line?

        private enum CodingKeys: String, CodingKey {
            case path, familyID, codePage, polygons, lines, points, exact, all
            case inexactCodes, labels, image, line
        }

        /// Written by hand, so the optional expectations may simply be absent. The
        /// synthesized decoder would throw on a missing key even where the property has
        /// a default value.
        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            path = try values.decode(String.self, forKey: .path)
            familyID = try values.decode(Int.self, forKey: .familyID)
            codePage = try values.decode(Int.self, forKey: .codePage)
            polygons = try values.decode(Int.self, forKey: .polygons)
            lines = try values.decode(Int.self, forKey: .lines)
            points = try values.decode(Int.self, forKey: .points)
            exact = try values.decode(Int.self, forKey: .exact)
            all = try values.decode(Int.self, forKey: .all)
            inexactCodes = try values.decodeIfPresent([Int].self, forKey: .inexactCodes) ?? []
            labels = try values.decodeIfPresent([Label].self, forKey: .labels) ?? []
            image = try values.decodeIfPresent(Image.self, forKey: .image)
            line = try values.decodeIfPresent(Line.self, forKey: .line)
        }
    }

    let suggestion: [Suggestion]
    let reader: [Reader]
    let typ: [Typ]

    private enum CodingKeys: String, CodingKey {
        case suggestion, reader, typ
    }

    /// Any section may be absent.
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        suggestion = try values.decodeIfPresent([Suggestion].self, forKey: .suggestion) ?? []
        reader = try values.decodeIfPresent([Reader].self, forKey: .reader) ?? []
        typ = try values.decodeIfPresent([Typ].self, forKey: .typ) ?? []
    }

    static var url: URL {
        if let named = ProcessInfo.processInfo.environment["KMAP_TEST_MAPS"] {
            return URL(fileURLWithPath: named)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".kmap/test-maps.json")
    }

    /// The file's contents, or nil where it does not exist or cannot be read.
    static func load() -> LocalTestMaps? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(LocalTestMaps.self, from: data)
    }
}
