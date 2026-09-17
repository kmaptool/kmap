import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Whether a login works: the service is asked the way pyhgtmap asks it, and the answer
/// is remembered so the build form does not log in on every keystroke.
extension ElevationLogins {
    /// What asking the service itself said.
    enum Verdict: String, Codable {
        /// The service accepted these credentials.
        case valid
        /// The service refused them. The only verdict that hides a source.
        case rejected
        /// No answer, or an unrecognised page. Says nothing about the credentials.
        case unreachable
    }

    /// The last answer, with the account name it was given for, never the password.
    /// `save` clears it whenever either half is written.
    struct Check: Codable, Equatable {
        var user: String
        var verdict: Verdict
    }

    private static let timeout: TimeInterval = 30

    /// Where the verdicts live: kmap's own settings, since the pyhgtmap config file has
    /// no field for them.
    private static var checksFile: URL {
        Paths.root.appendingPathComponent("elevation-logins.json")
    }

    static func check(_ service: Service) -> Check? {
        guard let data = try? Data(contentsOf: checksFile),
              let all = try? JSONDecoder().decode([String: Check].self, from: data),
              let mine = all[service.rawValue] else { return nil }
        // A verdict recorded against a different account name does not apply.
        return mine.user == load(service).user ? mine : nil
    }

    static func remember(_ service: Service, _ verdict: Verdict) {
        var all: [String: Check] = [:]
        if let data = try? Data(contentsOf: checksFile),
           let stored = try? JSONDecoder().decode([String: Check].self, from: data) {
            all = stored
        }
        all[service.rawValue] = Check(user: load(service).user, verdict: verdict)
        guard let data = try? JSONEncoder().encode(all) else { return }
        try? data.write(to: checksFile, options: .atomic)
    }

    static func forget(_ service: Service) {
        guard let data = try? Data(contentsOf: checksFile),
              var all = try? JSONDecoder().decode([String: Check].self, from: data) else { return }
        all[service.rawValue] = nil
        guard let encoded = try? JSONEncoder().encode(all) else { return }
        try? encoded.write(to: checksFile, options: .atomic)
    }

    /// Asks the service whether these credentials work: JAXA over HTTP Basic, USGS through
    /// its login form. An unrecognised response is `unreachable`, never `rejected`.
    static func verify(_ service: Service) async -> Verdict {
        let login = load(service)
        guard !login.user.isEmpty, !login.password.isEmpty else { return .rejected }
        let verdict: Verdict
        switch service {
        case .alos: verdict = await verifyBasic(login)
        case .srtm: verdict = await verifyUSGSForm(login)
        }
        remember(service, verdict)
        return verdict
    }

    /// JAXA serves the archives from a Basic-auth directory: a HEAD settles it, 401 or 403
    /// being a refusal.
    private static func verifyBasic(_ login: (user: String, password: String)) async -> Verdict {
        guard let url = URL(string: "https://www.eorc.jaxa.jp/ALOS/aw3d30/data/release_v2303/"),
              let credentials = "\(login.user):\(login.password)"
                .data(using: .utf8)?.base64EncodedString() else { return .unreachable }
        var request = URLRequest(url: url)
        request.httpMethod = "HEAD"
        request.timeoutInterval = timeout
        request.setValue("Basic \(credentials)", forHTTPHeaderField: "Authorization")
        guard let (_, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse else { return .unreachable }
        if http.statusCode == 401 || http.statusCode == 403 { return .rejected }
        return (200...399).contains(http.statusCode) ? .valid : .unreachable
    }

    /// USGS keeps SRTM behind the EROS registration system: a form, a CSRF token in hidden
    /// inputs, and a session cookie afterwards.
    private static func verifyUSGSForm(_ login: (user: String, password: String)) async -> Verdict {
        guard let entry = URL(string: "https://ers.cr.usgs.gov/login") else { return .unreachable }
        let session = URLSession(configuration: .ephemeral)
        guard let (data, _) = try? await session.data(from: entry),
              let page = String(data: data, encoding: .utf8),
              page.contains("loginForm") else { return .unreachable }

        var fields = ["username": login.user, "password": login.password]
        // Every hidden input is carried across under its own name, whatever the token is
        // called this year.
        for tag in page.allMatches("(?is)<input[^>]*type=[\"']hidden[\"'][^>]*>") {
            guard let name = attribute("name", in: tag) else { continue }
            fields[name] = attribute("value", in: tag) ?? ""
        }

        var request = URLRequest(url: entry)
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = fields.map { key, value in
            "\(escape(key))=\(escape(value))"
        }.joined(separator: "&").data(using: .utf8)

        guard let (body, response) = try? await session.data(for: request),
              let http = response as? HTTPURLResponse else { return .unreachable }
        let text = String(data: body, encoding: .utf8) ?? ""
        // Wrong credentials return the form again with an error; correct ones redirect.
        if text.localizedCaseInsensitiveContains("invalid username or password")
            || text.localizedCaseInsensitiveContains("your account is locked") {
            return .rejected
        }
        if text.contains("loginForm") && text.localizedCaseInsensitiveContains("error") {
            return .rejected
        }
        return (200...399).contains(http.statusCode) ? .valid : .unreachable
    }

    private static func escape(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? value
    }

    private static func attribute(_ name: String, in tag: String) -> String? {
        tag.allMatches("(?i)\\b\(name)=[\"']([^\"']*)[\"']")
            .first?
            .allMatches("[\"']([^\"']*)[\"']")
            .first
            .map { String($0.dropFirst().dropLast()) }
    }
}
