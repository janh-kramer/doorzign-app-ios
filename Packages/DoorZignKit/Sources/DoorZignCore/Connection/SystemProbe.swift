import DoorZignAPI
import Foundation

/// Ergebnis der Verbindungsprüfung vor der Anmeldung.
public struct ProbeResult: Sendable, Equatable {
    public let baseURL: URL
    public let system: SystemInfo
    /// Vom Server präsentierter Fingerprint (bei Edge immer gesetzt, bei Cloud `nil`).
    public let presentedFingerprint: String?
}

public enum ProbeError: Error, Equatable, Sendable, LocalizedError {
    /// Keine der Adressen war erreichbar; enthält den letzten Fehler.
    case unreachable(APIError)
    /// Gepinnter Fingerprint passt nicht zum Zertifikat.
    case fingerprintMismatch(presented: String)
    /// QR-Code gehört zu einer anderen Installation.
    case instanceMismatch(expected: String, actual: String)

    public var errorDescription: String? {
        switch self {
        case .unreachable(let error):
            error.message
        case .fingerprintMismatch:
            L("Das Zertifikat des Systems stimmt nicht mit dem QR-Code überein. Bitte den QR-Code in der Edge-Weboberfläche unter „Mobile App verbinden“ erneut scannen.")
        case .instanceMismatch:
            L("Unter dieser Adresse antwortet eine andere DoorZign-Installation als im QR-Code angegeben.")
        }
    }
}

/// Prüft Adressen per `GET /system`, bevor ein Profil angelegt wird.
public enum SystemProbe {
    /// Probiert die Adressen der Reihe nach. `trust` gilt für alle Adressen.
    public static func probe(
        urls: [URL],
        trust: TrustPolicy,
        expectedInstanceId: String? = nil
    ) async throws -> ProbeResult {
        var lastError = APIError(code: "unreachable", message: L("Das System ist nicht erreichbar."))
        for url in urls {
            let connection = ClientFactory.makeConnection(baseURL: url, trust: trust)
            defer { connection.session.finishTasksAndInvalidate() }
            do {
                let output = try await connection.client.getSystem()
                let system = SystemInfo(try output.ok.body.json)
                if let expectedInstanceId, system.instanceId != expectedInstanceId {
                    throw ProbeError.instanceMismatch(expected: expectedInstanceId, actual: system.instanceId)
                }
                return ProbeResult(
                    baseURL: url,
                    system: system,
                    presentedFingerprint: connection.delegate.observedFingerprint
                )
            } catch let error as ProbeError {
                throw error
            } catch {
                if case .pinned(let expected) = trust,
                   let presented = connection.delegate.observedFingerprint, presented != expected {
                    throw ProbeError.fingerprintMismatch(presented: presented)
                }
                lastError = APIError.from(error)
            }
        }
        throw ProbeError.unreachable(lastError)
    }
}
