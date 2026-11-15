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

    /// Bekannte `error.code`s zeigen eigene, übersetzte Texte (Glossar-Regel); `error.message` nur bei
    /// `validation` und unbekannten Codes (kommt in der Sprache aus `Accept-Language`, sonst Deutsch).
    public init(_ response: Components.Schemas.ErrorResponse, statusCode: Int?) {
        let message = Self.localizedMessage(code: response.error.code) ?? response.error.message
        self.init(
            code: response.error.code,
            message: message,
            fields: response.error.fields?.additionalProperties ?? [:],
            statusCode: statusCode
        )
    }

    /// Antwort, die der Vertrag nicht vorsieht.
    /// Eigener Text für bekannte Fehlercodes, `nil` = Text des Servers verwenden.
    public static func localizedMessage(code: String) -> String? {
        switch code {
        case "unauthorized": L("Bitte erneut anmelden.")
        case "token_expired": L("Deine Anmeldung ist abgelaufen. Bitte melde dich erneut an.")
        case "forbidden": L("Dafür fehlt die Berechtigung.")
        case "not_found": L("Nicht gefunden.")
        case "unlicensed": unlicensedMessage
        case "precondition_failed": L("Inzwischen geändert. Bitte neu laden.")
        case "too_large": L("Die Datei ist zu groß.")
        case "rate_limited": L("Zu viele Versuche. Bitte später erneut versuchen.")
        case "unavailable": L("Das System ist vorübergehend nicht verfügbar. Bitte gleich erneut versuchen.")
        case "conflict": L("Das System ist gerade beschäftigt. Bitte erneut versuchen.")
        case "internal": L("Interner Serverfehler. Bitte später erneut versuchen.")
        default: nil
        }
    }

    /// Anmeldung mit Passwort: 401 heißt falsche Zugangsdaten, nicht „erneut anmelden“.
    public var forLogin: APIError {
        statusCode == 401 && code == "unauthorized" ? with(message: L("Benutzername oder Passwort ist falsch.")) : self
    }

    /// SSO-Abschluss: `invalid_grant` = Code abgelaufen (60 s), schon benutzt oder Verifier falsch.
    public var forSSO: APIError {
        code == "invalid_grant" ? with(message: L("Die Anmeldung ist abgelaufen. Bitte erneut anmelden.")) : self
    }

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
