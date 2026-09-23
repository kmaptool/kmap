import Foundation

/// Logins for the 1 arc-second elevation sources, both of which need a free registration:
/// `srtm1` with USGS EarthExplorer, `alos1` with JAXA AW3D30.
///
/// Credentials are read from and written to pyhgtmap's own config file and nowhere else.
/// Whether they work is asked and remembered in `ElevationLoginsVerify.swift`.
enum ElevationLogins {
    /// The services pyhgtmap can authenticate against.
    enum Service: String, CaseIterable {
        case srtm, alos

        var displayName: String {
            switch self {
            case .srtm: return "USGS"
            case .alos: return "JAXA"
            }
        }

        var registerURL: String {
            switch self {
            case .srtm: return "ers.cr.usgs.gov/register"
            case .alos: return "eorc.jaxa.jp/ALOS/en/aw3d30"
            }
        }

        /// The elevation sources that fetch through this login.
        var sourceIDs: [String] {
            switch self {
            case .srtm: return ["srtm1", "srtm3"]
            case .alos: return ["alos1", "alos3"]
            }
        }
    }

    static var configFile: URL {
        Paths.home.appendingPathComponent(".pyhgtmap/config.yaml")
    }

    /// pyhgtmap uses ConfigArgParse: keys are its long option names without the leading
    /// dashes. A nested `srtm:` block would collapse to `--srtm=`, which it rejects as
    /// ambiguous against `--srtm-user` and `--srtm-password`.
    private static func parse() -> [String: String] {
        guard let text = try? String(contentsOf: configFile, encoding: .utf8) else { return [:] }
        var values: [String: String] = [:]
        for rawLine in Lines.of(text) {
            // `Lines.of` strips a trailing carriage return, which `split` would leave on
            // the value.
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.hasPrefix("#"), let colon = line.firstIndex(of: ":") else { continue }
            let key = line[line.startIndex..<colon].trimmingCharacters(in: .whitespacesAndNewlines)
            let value = line[line.index(after: colon)...]
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            values[key] = value
        }
        return values
    }

    static func load(_ service: Service) -> (user: String, password: String) {
        let values = parse()
        return (
            values["\(service.rawValue)-user"] ?? "",
            values["\(service.rawValue)-password"] ?? ""
        )
    }

    static func save(_ service: Service, user: String, password: String) {
        var values = parse()
        values["\(service.rawValue)-user"] = user
        values["\(service.rawValue)-password"] = password

        Paths.ensure(configFile.deletingLastPathComponent())
        var yaml = "# Written by kmap. Used by pyhgtmap to fetch elevation data.\n"
        for (key, value) in values.sorted(by: { $0.key < $1.key }) where !value.isEmpty {
            yaml += "\(key): \(value)\n"
        }
        try? FileTools.write(yaml, to: configFile)
        // Mode 0600: the file holds passwords.
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: configFile.path
        )
        // The stored verdict belongs to the previous credentials.
        forget(service)
    }

    /// Whether a source behind this login is offered on the build form: false when there
    /// are no credentials or the service has refused them, true otherwise, so an
    /// `unreachable` verdict does not hide a source.
    static func usable(_ service: Service) -> Bool {
        let login = load(service)
        guard !login.user.isEmpty, !login.password.isEmpty else { return false }
        return check(service)?.verdict != .rejected
    }

    /// Every service a source list needs a login for, in the services' own order.
    static func needed(for sources: String) -> [Service] {
        Service.allCases.filter { service in
            service.sourceIDs.contains { sources.contains($0) }
        }
    }

    /// Which service a source list needs a login for, if any: the first where several.
    static func required(for sources: String) -> Service? {
        needed(for: sources).first
    }
}
