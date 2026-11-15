import DoorZignAPI
import Foundation

/// Fehler einer API-Anfrage in einer für die Oberfläche geeigneten Form.
public struct APIError: Error, Equatable, Sendable, LocalizedError {
    /// Maschinenlesbarer Code aus `ErrorResponse.error.code` (z. B. `validation`), sonst ein lokaler Code.
    public let code: String
    /// Deutscher Text zur Anzeige.
    public let message: String
    /// Feldfehler bei `validation` (Feldname → Meldungen).
    public let fields: [String: [String]]
    public let statusCode: Int?

    public init(code: String, message: String, fields: [String: [String]] = [:], statusCode: Int? = nil) {
        self.code = code
        self.message = message
        self.fields = fields
        self.statusCode = statusCode
    }

    public var errorDescription: String? { message }

    public init(_ response: Components.Schemas.ErrorResponse, statusCode: Int?) {
        self.init(
            code: response.error.code,
            message: response.error.message,
            fields: response.error.fields?.additionalProperties ?? [:],
            statusCode: statusCode
        )
    }

    /// Antwort, die der Vertrag nicht vorsieht.
    public static func unexpected(statusCode: Int) -> APIError {
        switch statusCode {
        case 401: APIError(code: "unauthorized", message: "Bitte erneut anmelden.", statusCode: statusCode)
        case 403: APIError(code: "forbidden", message: "Dafür fehlt die Berechtigung.", statusCode: statusCode)
        case 404: APIError(code: "not_found", message: "Nicht gefunden.", statusCode: statusCode)
        case 429: APIError(code: "rate_limited", message: "Zu viele Versuche. Bitte später erneut versuchen.", statusCode: statusCode)
        case 503: APIError(code: "unavailable", message: "Das System ist vorübergehend nicht verfügbar. Bitte gleich erneut versuchen.", statusCode: statusCode)
        case 500...: APIError(code: "unavailable", message: "Das System ist gerade nicht erreichbar (Fehler \(statusCode)).", statusCode: statusCode)
        default: APIError(code: "unexpected", message: "Unerwartete Antwort vom System (\(statusCode)).", statusCode: statusCode)
        }
    }

    /// Übersetzt Transport- und sonstige Fehler.
    public static func from(_ error: Error) -> APIError {
        if let apiError = error as? APIError { return apiError }
        if let authError = error as? AuthError, authError == .notAuthenticated {
            return APIError(code: "unauthorized", message: "Bitte erneut anmelden.")
        }
        let underlying = (error as? ClientErrorLike)?.underlyingError ?? error
        if let urlError = underlying as? URLError {
            switch urlError.code {
            case .cancelled:
                return APIError(code: "cancelled", message: "Abgebrochen.")
            case .notConnectedToInternet, .networkConnectionLost, .dataNotAllowed:
                return APIError(code: "offline", message: "Keine Netzwerkverbindung.")
            case .timedOut, .cannotConnectToHost, .cannotFindHost, .dnsLookupFailed:
                return APIError(code: "unreachable", message: "Das System ist nicht erreichbar.")
            case .serverCertificateUntrusted, .serverCertificateHasBadDate, .serverCertificateNotYetValid,
                 .serverCertificateHasUnknownRoot, .secureConnectionFailed, .clientCertificateRejected:
                return APIError(code: "tls", message: "Die sichere Verbindung konnte nicht hergestellt werden. Das Zertifikat stimmt nicht mit dem gespeicherten überein.")
            default:
                return APIError(code: "network", message: urlError.localizedDescription)
            }
        }
        if underlying is DecodingError {
            return APIError(code: "decoding", message: "Die Antwort des Systems ist nicht lesbar. Bitte App aktualisieren.")
        }
        return APIError(code: "unknown", message: underlying.localizedDescription)
    }
}

import OpenAPIRuntime

/// Abstraktion über `ClientError`, um an den eigentlichen Fehler zu kommen.
protocol ClientErrorLike {
    var underlyingError: any Error { get }
}

extension ClientError: ClientErrorLike {}
