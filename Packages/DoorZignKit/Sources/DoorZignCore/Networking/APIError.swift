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

    public static var unlicensedMessage: String { L("Für dieses Display ist keine gültige Lizenz vorhanden.") }
    public static var calendarUnlicensedMessage: String { L("Für dieses Display ist keine Kalenderlizenz vorhanden.") }

    public init(_ response: Components.Schemas.ErrorResponse, statusCode: Int?) {
        // Lizenzfehler (403 `unlicensed`) nicht als „Keine Berechtigung“ anzeigen.
        let message = response.error.code == "unlicensed" ? Self.unlicensedMessage : response.error.message
        self.init(
            code: response.error.code,
            message: message,
            fields: response.error.fields?.additionalProperties ?? [:],
            statusCode: statusCode
        )
    }

    /// Antwort, die der Vertrag nicht vorsieht.
    /// Gleicher Fehler mit anderem Anzeigetext.
    public func with(message: String) -> APIError {
        APIError(code: code, message: message, fields: fields, statusCode: statusCode)
    }

    /// Kalender-Kontext (PUT iCal, calendar/check): Lizenzfehler konkret benennen.
    public var forCalendar: APIError {
        code == "unlicensed" ? with(message: Self.calendarUnlicensedMessage) : self
    }

    public static func unexpected(statusCode: Int) -> APIError {
        switch statusCode {
        case 401: APIError(code: "unauthorized", message: L("Bitte erneut anmelden."), statusCode: statusCode)
        case 403: APIError(code: "forbidden", message: L("Dafür fehlt die Berechtigung."), statusCode: statusCode)
        case 404: APIError(code: "not_found", message: L("Nicht gefunden."), statusCode: statusCode)
        case 429: APIError(code: "rate_limited", message: L("Zu viele Versuche. Bitte später erneut versuchen."), statusCode: statusCode)
        case 503: APIError(code: "unavailable", message: L("Das System ist vorübergehend nicht verfügbar. Bitte gleich erneut versuchen."), statusCode: statusCode)
        case 500...: APIError(code: "unavailable", message: L("Das System ist gerade nicht erreichbar (Fehler \(statusCode))."), statusCode: statusCode)
        default: APIError(code: "unexpected", message: L("Unerwartete Antwort vom System (\(statusCode))."), statusCode: statusCode)
        }
    }

    /// Übersetzt Transport- und sonstige Fehler.
    public static func from(_ error: Error) -> APIError {
        if let apiError = error as? APIError { return apiError }
        if let authError = error as? AuthError, authError == .notAuthenticated {
            return APIError(code: "unauthorized", message: L("Bitte erneut anmelden."))
        }
        let underlying = (error as? ClientErrorLike)?.underlyingError ?? error
        if let urlError = underlying as? URLError {
            switch urlError.code {
            case .cancelled:
                return APIError(code: "cancelled", message: L("Abgebrochen."))
            case .notConnectedToInternet, .networkConnectionLost, .dataNotAllowed:
                return APIError(code: "offline", message: L("Keine Netzwerkverbindung."))
            case .timedOut, .cannotConnectToHost, .cannotFindHost, .dnsLookupFailed:
                return APIError(code: "unreachable", message: L("Das System ist nicht erreichbar."))
            case .serverCertificateUntrusted, .serverCertificateHasBadDate, .serverCertificateNotYetValid,
                 .serverCertificateHasUnknownRoot, .secureConnectionFailed, .clientCertificateRejected:
                return APIError(code: "tls", message: L("Die sichere Verbindung konnte nicht hergestellt werden. Das Zertifikat stimmt nicht mit dem gespeicherten überein."))
            default:
                return APIError(code: "network", message: urlError.localizedDescription)
            }
        }
        if underlying is DecodingError {
            return APIError(code: "decoding", message: L("Die Antwort des Systems ist nicht lesbar. Bitte App aktualisieren."))
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
