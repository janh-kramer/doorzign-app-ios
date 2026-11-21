import Foundation
import Observation

/// Verbindungslinks `doorzign://edge|cloud` (ui-spec §1 „Verbindungslinks“, decisions 45).
public enum LinkRouting {
    /// Wo die App gerade steht, soweit es für einen eingehenden Link zählt.
    public enum Context: Equatable, Sendable {
        case starting
        case onboarding
        case login
        case signedIn(ConnectionProfile)
    }

    public enum Decision: Equatable, Sendable {
        /// App startet noch: Link halten, bis die Phase feststeht.
        case wait
        /// Onboarding: roh übergeben und dort wie einen gescannten QR-Code prüfen.
        case onboarding
        /// Anmeldeseite, gültiger Link: System verlassen, dann im Onboarding prüfen.
        case leaveLogin
        /// Anmeldeseite, ungültiger Link: Verbindungsfehler als Hinweis, gewählte Verbindung bleibt.
        case invalidOnLogin
        /// Angemeldet, anderes System: Bestätigung wie „Mit anderem System verbinden“.
        case confirmSwitch
        /// Angemeldet und gleiches System oder ungültig: ohne Folgen verwerfen.
        case ignore
    }

    public static func decide(raw: String, context: Context) -> Decision {
        switch context {
        case .starting:
            return .wait
        case .onboarding:
            return .onboarding
        case .login:
            return (try? PairingLink.parse(raw)) == nil ? .invalidOnLogin : .leaveLogin
        case .signedIn(let profile):
            guard let link = try? PairingLink.parse(raw) else { return .ignore }
            return isSameSystem(link, as: profile) ? .ignore : .confirmSwitch
        }
    }

    /// Edge: gleiche `instanceId`; Cloud: gleiche Basis-URL.
    public static func isSameSystem(_ link: PairingLink, as profile: ConnectionProfile) -> Bool {
        switch link {
        case .edge(_, _, let instanceId, _):
            return profile.systemType == .edge && instanceId == profile.instanceId
        case .cloud(let url, _):
            return profile.systemType == .cloud && normalized(url) == normalized(profile.baseURL)
        }
    }

    static func normalized(_ url: URL) -> String {
        let base = APIBase.mobileBase(url)
        let scheme = base.scheme?.lowercased() ?? "https"
        let port = base.port.map { ($0 == 443 && scheme == "https") ? "" : ":\($0)" } ?? ""
        return "\(scheme)://\(base.host?.lowercased() ?? "")\(port)\(base.path)"
    }
}

extension AppSession.Phase {
    public var linkContext: LinkRouting.Context {
        switch self {
        case .starting: .starting
        case .onboarding: .onboarding
        case .login: .login
        case .signedIn(let context): .signedIn(context.profile)
        }
    }
}

/// Serialisiert Prüfschritte im Onboarding. Ein Link, der während einer Prüfung eingeht, bricht sie nicht ab,
/// sondern wird gehalten und danach übernommen; ein neuerer Link ersetzt einen gehaltenen.
@MainActor
@Observable
public final class LinkGate {
    public var isBusy: Bool { depth > 0 }
    /// Gehaltener Link (roh), der nach der laufenden Prüfung übernommen wird.
    public private(set) var heldLink: String?

    private var depth = 0
    @ObservationIgnored private var heldProcess: (@MainActor (String) async -> Void)?

    public init() {}

    /// Führt einen Prüfschritt aus (verschachtelt erlaubt). Danach kommt ein gehaltener Link an die Reihe.
    public func run(_ step: @MainActor () async -> Void) async {
        depth += 1
        await step()
        depth -= 1
        guard depth == 0, let raw = heldLink, let process = heldProcess else { return }
        heldLink = nil
        heldProcess = nil
        await process(raw)
    }

    /// Link sofort verarbeiten oder, solange eine Prüfung läuft, halten.
    public func submit(_ raw: String, process: @escaping @MainActor (String) async -> Void) async {
        if isBusy {
            heldLink = raw
            heldProcess = process
            return
        }
        await process(raw)
    }
}
