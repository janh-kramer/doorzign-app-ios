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
            L("Das Zertifikat des Systems stimmt nicht mit dem QR-Code überein. Bitte den QR-Code in der Edge-Weboberfläche unter „Doorzign-App verbinden“ erneut scannen.")
        case .instanceMismatch:
            L("Unter dieser Adresse antwortet eine andere Doorzign-Installation als im QR-Code angegeben.")
        }
    }
}

/// Prüft Adressen per `GET /system`, bevor ein Profil angelegt wird.
///
/// Mehrere Adressen (decisions 36, docs/edge-connection.md): alle werden gleichzeitig geprüft.
/// Antwortet die erste Adresse (Master) innerhalb von `masterGrace` gültig, gewinnt sie, sonst die
/// erste gültige Antwort. Gültig heißt: erreichbar, Fingerprint und instanceId passen. Die übrigen
/// Prüfungen werden abgebrochen.
public enum SystemProbe {
    /// Vorrang der ersten Adresse.
    public static let masterGrace: Duration = .seconds(1)

    public static func probe(
        urls: [URL],
        trust: TrustPolicy,
        expectedInstanceId: String? = nil
    ) async throws -> ProbeResult {
        try await race(count: urls.count, masterGrace: masterGrace) { index in
            try await probeOne(url: urls[index], trust: trust, expectedInstanceId: expectedInstanceId)
        }
    }

    /// Prüft eine Adresse. Wirft `ProbeError.fingerprintMismatch`/`.instanceMismatch` oder den Transportfehler.
    static func probeOne(url: URL, trust: TrustPolicy, expectedInstanceId: String?) async throws -> ProbeResult {
        let connection = ClientFactory.makeConnection(baseURL: url, trust: trust)
        defer { connection.session.invalidateAndCancel() }
        do {
            let output = try await connection.client.getSystem()
            let system = SystemInfo(try output.ok.body.json)
            if let expectedInstanceId, system.instanceId != expectedInstanceId {
                throw ProbeError.instanceMismatch(expected: expectedInstanceId, actual: system.instanceId)
            }
            return ProbeResult(baseURL: url, system: system, presentedFingerprint: connection.delegate.observedFingerprint)
        } catch let error as ProbeError {
            throw error
        } catch {
            if case .pinned(let expected) = trust,
               let presented = connection.delegate.observedFingerprint, presented != expected {
                throw ProbeError.fingerprintMismatch(presented: presented)
            }
            throw error
        }
    }

    /// Auswahlregel, getrennt vom Netzwerk testbar. `attempt(i)` prüft Adresse `i` (0 = Master).
    /// Ohne gültige Antwort: Fingerprint-Fehler vor instanceId-Fehler vor „nicht erreichbar“
    /// (mit dem Fehler des Masters, sonst dem der ersten Adresse mit Fehler).
    static func race<T: Sendable>(
        count: Int,
        masterGrace: Duration,
        attempt: @escaping @Sendable (Int) async throws -> T
    ) async throws -> T {
        guard count > 0 else {
            throw ProbeError.unreachable(APIError(code: "unreachable", message: L("Das System ist nicht erreichbar.")))
        }
        return try await withThrowingTaskGroup(of: RaceOutcome<T>.self) { group in
            for index in 0..<count {
                group.addTask {
                    do { return .success(index, try await attempt(index)) } catch { return .failure(index, error) }
                }
            }
            if count > 1 {
                group.addTask {
                    try? await Task.sleep(for: masterGrace)
                    return .graceElapsed
                }
            }
            var masterFinished = count == 1
            var graceOver = count == 1
            var waiting: T?  // erste gültige Antwort einer anderen Adresse, solange der Master Vorrang hat
            var failures: [Int: any Error] = [:]

            while let outcome = try await group.next() {
                switch outcome {
                case .success(0, let result):
                    group.cancelAll()
                    return result
                case .success(_, let result):
                    if masterFinished || graceOver {
                        group.cancelAll()
                        return result
                    }
                    if waiting == nil { waiting = result }
                case .failure(let index, let error):
                    failures[index] = error
                    if index == 0 { masterFinished = true }
                    if masterFinished, let waiting {
                        group.cancelAll()
                        return waiting
                    }
                case .graceElapsed:
                    graceOver = true
                    if let waiting {
                        group.cancelAll()
                        return waiting
                    }
                }
                if failures.count == count {
                    group.cancelAll()
                    break
                }
            }
            throw combinedError(failures)
        }
    }

    private static func combinedError(_ failures: [Int: any Error]) -> any Error {
        let ordered = failures.sorted { $0.key < $1.key }.map(\.value)
        if let mismatch = ordered.first(where: { if case ProbeError.fingerprintMismatch = $0 { true } else { false } }) {
            return mismatch
        }
        if let mismatch = ordered.first(where: { if case ProbeError.instanceMismatch = $0 { true } else { false } }) {
            return mismatch
        }
        let first = ordered.first.map { APIError.from($0) }
            ?? APIError(code: "unreachable", message: L("Das System ist nicht erreichbar."))
        return ProbeError.unreachable(first)
    }
}

private enum RaceOutcome<T: Sendable>: Sendable {
    case success(Int, T)
    case failure(Int, any Error)
    case graceElapsed
}
