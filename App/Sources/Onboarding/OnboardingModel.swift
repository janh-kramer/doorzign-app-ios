import DoorZignCore
import Foundation
import Observation

/// Ablauflogik des Onboardings: Adressen prüfen, Fingerprint bestätigen lassen, Anmeldung vorbereiten.
@MainActor
@Observable
final class OnboardingModel {
    /// Fingerprint, den der Benutzer bestätigen muss (Trust on first use).
    struct PendingTrust: Identifiable {
        let id = UUID()
        let probe: ProbeResult
        let fingerprint: String
    }

    var errorMessage: String?
    var pendingTrust: PendingTrust?
    /// Serialisiert die Prüfungen; Verbindungslinks warten auf eine laufende Prüfung (decisions 45).
    let gate = LinkGate()
    var isBusy: Bool { gate.isBusy }

    // MARK: QR-Code / Link

    /// Geöffneter Verbindungslink (`onOpenURL`), roh: wird wie ein gescannter QR-Code geprüft. Läuft gerade
    /// eine Prüfung, wird er gehalten und danach übernommen – die laufende Prüfung wird nicht abgebrochen.
    func receiveLink(_ raw: String, session: AppSession) async {
        await gate.submit(raw) { [weak self] raw in
            await self?.connect(scannedCode: raw, session: session)
        }
    }

    func connect(link: PairingLink, session: AppSession) async {
        await run {
            switch link {
            case .edge(let urls, let fingerprint, let instanceId, _):
                let probe = try await SystemProbe.probe(
                    urls: urls,
                    trust: .pinned(fingerprint: fingerprint),
                    expectedInstanceId: instanceId
                )
                return await session.prepareLogin(probe: probe, pinnedFingerprint: fingerprint, alternativeURLs: urls)
            case .cloud(let url, _):
                let probe = try await SystemProbe.probe(urls: [url], trust: .system)
                return await session.prepareLogin(probe: probe, pinnedFingerprint: nil)
            }
        }
    }

    func connect(scannedCode: String, session: AppSession) async {
        do {
            await connect(link: try PairingLink.parse(scannedCode), session: session)
        } catch {
            errorMessage = String(localized: "Dieser QR-Code ist kein Doorzign-Verbindungscode.")
        }
    }

    // MARK: Edge ohne QR-Code (TOFU)

    func connectEdge(address: String) async {
        guard let url = APIBase.edge(fromInput: address) else {
            errorMessage = String(localized: "Bitte eine gültige Adresse eingeben, z. B. 192.168.1.10 oder gateway.local:9443.")
            return
        }
        await probeForTrust(url: url)
    }

    func connectEdge(gateway: DiscoveredGateway) async {
        await gate.run {
            do {
                let url = try await GatewayBrowser.resolve(gateway)
                await probeForTrust(url: url)
            } catch {
                errorMessage = String(localized: "Das Gateway „\(gateway.displayName)“ konnte nicht erreicht werden.")
            }
        }
    }

    private func probeForTrust(url: URL) async {
        await gate.run {
            do {
                let probe = try await SystemProbe.probe(urls: [url], trust: .captureForConfirmation)
                guard let fingerprint = probe.presentedFingerprint else {
                    errorMessage = String(localized: "Das Gateway hat kein Zertifikat vorgelegt.")
                    return
                }
                pendingTrust = PendingTrust(probe: probe, fingerprint: fingerprint)
            } catch {
                errorMessage = (error as? LocalizedError)?.errorDescription ?? APIError.from(error).message
            }
        }
    }

    /// Der Benutzer hat den Fingerprint verglichen und bestätigt.
    func confirmTrust(_ trust: PendingTrust, session: AppSession) async {
        pendingTrust = nil
        await run {
            await session.prepareLogin(probe: trust.probe, pinnedFingerprint: trust.fingerprint)
        }
    }

    // MARK: Cloud

    func connectCloud(input: String, session: AppSession) async {
        guard let url = APIBase.cloud(fromInput: input) else {
            errorMessage = String(localized: "Bitte den Namen der Instanz (z. B. „firma“) oder die vollständige Adresse eingeben.")
            return
        }
        await run {
            let probe = try await SystemProbe.probe(urls: [url], trust: .system)
            return await session.prepareLogin(probe: probe, pinnedFingerprint: nil)
        }
    }

    #if DEBUG
    /// Entwicklung gegen den Prism-Mock (Pfade ohne /mobile/v1, nur HTTP).
    func connectMock(address: String, session: AppSession) async {
        guard let url = URL(string: address) else { return }
        await run {
            let probe = try await SystemProbe.probe(urls: [url], trust: .system)
            return await session.prepareLogin(probe: probe, pinnedFingerprint: nil)
        }
    }
    #endif

    // MARK: Hilfen

    /// Führt einen Schritt aus; `APIError` als Rückgabe oder geworfene Fehler landen in `errorMessage`.
    private func run(_ step: () async throws -> APIError?) async {
        await gate.run {
            errorMessage = nil
            do {
                if let error = try await step() {
                    errorMessage = error.message
                }
            } catch {
                errorMessage = (error as? LocalizedError)?.errorDescription ?? APIError.from(error).message
            }
        }
    }
}

/// SwiftUI-Hülle um den mDNS-Browser.
@MainActor
@Observable
final class GatewaySearch {
    private(set) var gateways: [DiscoveredGateway] = []
    private(set) var state: GatewayBrowser.State = .idle
    @ObservationIgnored private let browser = GatewayBrowser()

    init() {
        browser.onChange = { [weak self] in
            guard let self else { return }
            self.gateways = self.browser.gateways
            self.state = self.browser.state
        }
    }

    func start() { browser.start() }
    func stop() { browser.stop() }
}
