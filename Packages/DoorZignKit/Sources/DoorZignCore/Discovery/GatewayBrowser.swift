import Foundation
import Network

/// Ein per mDNS gefundenes Edge-Gateway.
public struct DiscoveredGateway: Identifiable, Hashable, Sendable {
    public var id: String { serviceName }
    public let serviceName: String
    /// Aus dem TXT-Record (`name`), sonst der Dienstname.
    public let displayName: String
    /// `id` aus dem TXT-Record, falls vorhanden.
    public let instanceId: String?
    /// `node` aus dem TXT-Record (Gatewayname im Verbund).
    public let node: String?
    /// `fp` aus dem TXT-Record. Nicht authentisch – nur zur Information, es gilt trotzdem TOFU.
    public let advertisedFingerprint: String?
    /// HTTPS-Port aus dem TXT-Record (`https`), sonst `APIBase.defaultEdgePort` (9443).
    public let httpsPort: Int
    let endpoint: NWEndpoint

    public static func == (lhs: Self, rhs: Self) -> Bool { lhs.serviceName == rhs.serviceName }
    public func hash(into hasher: inout Hasher) { hasher.combine(serviceName) }
}

/// Sucht Doorzign-Gateways im lokalen Netz (`_doorzign._tcp`).
/// Erfordert `NSLocalNetworkUsageDescription` und `NSBonjourServices` in der Info.plist.
@MainActor
public final class GatewayBrowser {
    public static let serviceType = "_doorzign._tcp"

    public enum State: Equatable, Sendable {
        case idle
        case searching
        /// z. B. Zugriff auf lokales Netzwerk verweigert.
        case failed(String)
    }

    public private(set) var gateways: [DiscoveredGateway] = []
    public private(set) var state: State = .idle
    public var onChange: (() -> Void)?

    private var browser: NWBrowser?

    public init() {}

    public func start() {
        stop()
        let browser = NWBrowser(for: .bonjourWithTXTRecord(type: Self.serviceType, domain: nil), using: .tcp)
        browser.stateUpdateHandler = { [weak self] newState in
            Task { @MainActor in self?.handle(state: newState) }
        }
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            let found = results.compactMap(Self.gateway(from:)).sorted { $0.displayName < $1.displayName }
            Task { @MainActor in
                self?.gateways = found
                self?.onChange?()
            }
        }
        self.browser = browser
        state = .searching
        browser.start(queue: .main)
        onChange?()
    }

    public func stop() {
        browser?.cancel()
        browser = nil
        if state == .searching { state = .idle }
    }

    private func handle(state newState: NWBrowser.State) {
        switch newState {
        case .failed(let error), .waiting(let error):
            state = .failed(Self.describe(error))
        case .cancelled:
            state = .idle
        default:
            break
        }
        onChange?()
    }

    private static func describe(_ error: NWError) -> String {
        if case .dns(let code) = error, code == -65570 /* kDNSServiceErr_PolicyDenied */ {
            return L("Kein Zugriff auf das lokale Netzwerk. Bitte in den Einstellungen unter „Doorzign“ erlauben.")
        }
        return L("Suche im Netzwerk nicht möglich (\(error.localizedDescription)).")
    }

    nonisolated static func gateway(from result: NWBrowser.Result) -> DiscoveredGateway? {
        guard case .service(let name, _, _, _) = result.endpoint else { return nil }
        var txt: [String: String] = [:]
        if case .bonjour(let record) = result.metadata {
            txt = record.dictionary
        }
        return DiscoveredGateway(
            serviceName: name,
            displayName: txt["name"].flatMap { $0.isEmpty ? nil : $0 } ?? name,
            instanceId: txt["id"],
            node: txt["node"],
            advertisedFingerprint: txt["fp"].flatMap(Fingerprint.normalize),
            httpsPort: txt["https"].flatMap(Int.init) ?? APIBase.defaultEdgePort,
            endpoint: result.endpoint
        )
    }

    /// Löst den Dienst in eine Basis-URL auf (`https://<host>:<httpsPort>/mobile/v1`).
    public nonisolated static func resolve(_ gateway: DiscoveredGateway, timeout: TimeInterval = 5) async throws -> URL {
        let connection = NWConnection(to: gateway.endpoint, using: .tcp)
        defer { connection.cancel() }
        let host: String = try await withCheckedThrowingContinuation { continuation in
            let once = OnceFlag()
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    guard once.claim() else { return }
                    if case .hostPort(let host, _) = connection.currentPath?.remoteEndpoint {
                        continuation.resume(returning: Self.urlHost(host))
                    } else {
                        continuation.resume(throwing: URLError(.cannotFindHost))
                    }
                case .failed(let error):
                    guard once.claim() else { return }
                    continuation.resume(throwing: error)
                default:
                    break
                }
            }
            connection.start(queue: .global())
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                guard once.claim() else { return }
                continuation.resume(throwing: URLError(.timedOut))
            }
        }
        guard let url = URL(string: "https://\(host):\(gateway.httpsPort)") else { throw URLError(.badURL) }
        return APIBase.mobileBase(url)
    }

    nonisolated static func urlHost(_ host: NWEndpoint.Host) -> String {
        switch host {
        case .ipv4(let address):
            return "\(address)".components(separatedBy: "%").first ?? "\(address)"
        case .ipv6(let address):
            // Zonen-ID muss in URLs als %25 kodiert werden.
            let text = "\(address)".replacingOccurrences(of: "%", with: "%25")
            return "[\(text)]"
        case .name(let name, _):
            return name
        @unknown default:
            return "\(host)"
        }
    }
}

/// Einmal-Flag für Continuations, die von mehreren Stellen aufgelöst werden könnten.
final class OnceFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var claimed = false

    func claim() -> Bool {
        lock.withLock {
            if claimed { return false }
            claimed = true
            return true
        }
    }
}
