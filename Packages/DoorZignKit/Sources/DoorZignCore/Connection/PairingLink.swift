import Foundation

/// Inhalt eines Verbindungs-QR-Codes bzw. Links.
/// - Edge: `doorzign://edge?u=<origin1>,<origin2>&fp=<CA-sha256>&i=<instanceId>&n=<Name>`
/// - Cloud: `doorzign://cloud?u=<url>&n=<Name>`
/// Siehe docs/edge-connection.md im Koordinations-Repo.
public enum PairingLink: Equatable, Sendable {
    case edge(urls: [URL], fingerprint: String, instanceId: String, name: String?)
    case cloud(url: URL, name: String?)

    public enum ParseError: Error, Equatable {
        case notDoorzign
        case missingParameter(String)
        case invalidURL(String)
        case invalidFingerprint
    }

    public static func parse(_ string: String) throws -> PairingLink {
        guard let components = URLComponents(string: string.trimmingCharacters(in: .whitespacesAndNewlines)),
              components.scheme?.lowercased() == "doorzign"
        else { throw ParseError.notDoorzign }

        let query = Dictionary(
            (components.queryItems ?? []).map { ($0.name, $0.value ?? "") },
            uniquingKeysWith: { first, _ in first }
        )
        func required(_ name: String) throws -> String {
            guard let value = query[name], !value.isEmpty else { throw ParseError.missingParameter(name) }
            return value
        }

        let name = query["n"].flatMap { $0.isEmpty ? nil : $0 }

        switch components.host?.lowercased() {
        case "edge":
            let urls = try required("u").split(separator: ",").map { raw -> URL in
                let text = String(raw).trimmingCharacters(in: .whitespaces)
                guard let url = URL(string: text), url.scheme?.lowercased() == "https", url.host != nil else {
                    throw ParseError.invalidURL(text)
                }
                return url
            }
            guard !urls.isEmpty else { throw ParseError.missingParameter("u") }
            guard let fp = Fingerprint.normalize(try required("fp")) else { throw ParseError.invalidFingerprint }
            return .edge(urls: urls.map(APIBase.mobileBase), fingerprint: fp, instanceId: try required("i"), name: name)

        case "cloud":
            let text = try required("u")
            guard let url = URL(string: text), url.scheme?.lowercased() == "https", url.host != nil else {
                throw ParseError.invalidURL(text)
            }
            return .cloud(url: APIBase.mobileBase(url), name: name)

        default:
            throw ParseError.notDoorzign
        }
    }
}

/// Bildung der API-Basis-URLs aus Benutzereingaben.
public enum APIBase {
    public static let pathPrefix = "/mobile/v1"
    public static let defaultEdgePort = 8443
    public static let cloudDomain = "zeitwart.de"

    /// Hängt `/mobile/v1` an, falls noch nicht vorhanden; entfernt abschließende Schrägstriche.
    public static func mobileBase(_ url: URL) -> URL {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url }
        var path = components.path
        while path.hasSuffix("/") { path.removeLast() }
        if !path.hasSuffix(pathPrefix) { path += pathPrefix }
        components.path = path
        components.query = nil
        components.fragment = nil
        return components.url ?? url
    }

    /// Cloud-Eingabe: `firma` → `https://firma.zeitwart.de/mobile/v1`; volle URL oder Hostname ebenfalls erlaubt.
    public static func cloud(fromInput input: String) -> URL? {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if text.contains("://") {
            guard let url = URL(string: text), url.scheme?.lowercased() == "https", url.host != nil else { return nil }
            return mobileBase(url)
        }
        let host = text.contains(".") ? text.lowercased() : "\(text.lowercased()).\(cloudDomain)"
        guard host.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" || $0 == "." || $0 == ":" }),
              let url = URL(string: "https://\(host)")
        else { return nil }
        return mobileBase(url)
    }

    /// Edge-Eingabe: `host[:port]` → `https://host:8443/mobile/v1`. Volle https-URL ebenfalls erlaubt.
    public static func edge(fromInput input: String) -> URL? {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        let candidate = text.contains("://") ? text : "https://\(text)"
        guard var components = URLComponents(string: candidate),
              components.scheme?.lowercased() == "https",
              let host = components.host, !host.isEmpty
        else { return nil }
        if components.port == nil { components.port = defaultEdgePort }
        guard let url = components.url else { return nil }
        return mobileBase(url)
    }
}
