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
    ///
    /// The file is ConfigArgParse's own format, not YAML: `key: value`, with 1 pair of
    /// matching quotes taken off and no escapes. Read here by the same expression.
    private static let line = try? NSRegularExpression(
        pattern: #"^(?<key>[^:=;#\s]+)\s*"#
            + #"(?:(?<equal>[:=\s])\s*(['"]?)(?<value>.+?)?\3)?"#
            + #"\s*(?:\s[;#]\s*(?<comment>.*?)\s*)?$"#
    )

    private static func parse() -> [String: String] {
        guard let text = try? String(contentsOf: configFile, encoding: .utf8) else { return [:] }
        return parse(text)
    }

    static func parse(_ text: String) -> [String: String] {
        guard let line else { return [:] }
        var values: [String: String] = [:]
        // `Lines.of` strips a trailing carriage return, which would end up in the value.
        for rawLine in Lines.of(text) {
            let trimmed = rawLine.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, !"#;[".contains(trimmed.first!), !trimmed.hasPrefix("---") else { continue }
            let range = NSRange(trimmed.startIndex..., in: trimmed)
            guard let match = line.firstMatch(in: trimmed, range: range),
                let key = Range(match.range(withName: "key"), in: trimmed)
            else { continue }
            let value = Range(match.range(withName: "value"), in: trimmed).map { String(trimmed[$0]) } ?? ""
            values[String(trimmed[key])] = value
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

    enum Trouble: Error, LocalizedError {
        /// What pyhgtmap's file cannot hold: a line break, or a value it would read as a list.
        case unwritable

        var errorDescription: String? {
            t("pyhgtmap's file cannot hold a value with a line break or in square brackets")
        }
    }

    /// Whether pyhgtmap would read back exactly this value from between double quotes.
    static func isWritable(_ value: String) -> Bool {
        !value.contains(where: { $0 == "\n" || $0 == "\r" }) && !(value.hasPrefix("[") && value.hasSuffix("]"))
    }

    /// The file's text. In double quotes: a `#` or `;` after a space would otherwise start
    /// a comment.
    static func render(_ values: [String: String]) -> String {
        var text = "# Written by kmap. Used by pyhgtmap to fetch elevation data.\n"
        for (key, value) in values.sorted(by: { $0.key < $1.key }) where !value.isEmpty {
            text += "\(key): \"\(value)\"\n"
        }
        return text
    }

    static func save(_ service: Service, user: String, password: String) throws {
        guard isWritable(user), isWritable(password) else { throw Trouble.unwritable }
        var values = parse()
        values["\(service.rawValue)-user"] = user
        values["\(service.rawValue)-password"] = password

        try FileManager.default.createDirectory(
            at: configFile.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try FileTools.writePrivate(render(values), to: configFile)
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
