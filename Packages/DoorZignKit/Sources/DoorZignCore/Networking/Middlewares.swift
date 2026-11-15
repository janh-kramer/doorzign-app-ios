import Foundation
import HTTPTypes
import OpenAPIRuntime

/// Setzt `Authorization: Bearer …` und behandelt 401 nach Vertrag:
/// - `token_expired` → einmal `/auth/refresh` (serialisiert über `TokenManager`), dann Wiederholung.
/// - jeder andere 401-Code → Token widerrufen/ungültig → Sitzung beenden (zur Anmeldung).
public struct AuthMiddleware: ClientMiddleware {
    /// Öffentliche Operationen ohne Bearer-Token.
    static let publicOperations: Set<String> = [
        "getSystem", "getAuthProviders", "login", "startSso", "exchangeSsoCode", "refreshToken",
    ]

    let tokens: TokenManager

    public init(tokens: TokenManager) {
        self.tokens = tokens
    }

    public func intercept(
        _ request: HTTPRequest,
        body: HTTPBody?,
        baseURL: URL,
        operationID: String,
        next: @Sendable (HTTPRequest, HTTPBody?, URL) async throws -> (HTTPResponse, HTTPBody?)
    ) async throws -> (HTTPResponse, HTTPBody?) {
        guard !Self.publicOperations.contains(operationID) else {
            return try await next(request, body, baseURL)
        }

        let token = try await tokens.validAccessToken()
        var authorized = request
        authorized.headerFields[.authorization] = "Bearer \(token)"
        let (response, responseBody) = try await next(authorized, body, baseURL)
        guard response.status == .unauthorized else { return (response, responseBody) }

        // Fehlercode lesen; der Body wird danach für den generierten Client neu aufgebaut.
        var data = Data()
        if let responseBody { data = try await Data(collecting: responseBody, upTo: 64 * 1024) }
        let rebuilt = HTTPBody(data)
        let code = (try? JSONDecoder().decode(ErrorEnvelope.self, from: data))?.error.code

        guard code == "token_expired" else {
            await tokens.invalidate(rejectedAccessToken: token)
            return (response, rebuilt)
        }
        // Body nicht wiederholbar (z. B. Upload-Stream): kein Wiederholungsversuch.
        guard body?.iterationBehavior != .single else { return (response, rebuilt) }

        let fresh: String
        do {
            fresh = try await tokens.refresh(rejectedAccessToken: token)
        } catch AuthError.notAuthenticated {
            return (response, rebuilt)
        }
        var retried = request
        retried.headerFields[.authorization] = "Bearer \(fresh)"
        return try await next(retried, body, baseURL)
    }

    private struct ErrorEnvelope: Decodable {
        struct Inner: Decodable { let code: String }
        let error: Inner
    }
}

/// Sprache der Fehlertexte; Englisch folgt später.
public struct AcceptLanguageMiddleware: ClientMiddleware {
    let language: String

    public init(language: String = "de") {
        self.language = language
    }

    public func intercept(
        _ request: HTTPRequest,
        body: HTTPBody?,
        baseURL: URL,
        operationID: String,
        next: @Sendable (HTTPRequest, HTTPBody?, URL) async throws -> (HTTPResponse, HTTPBody?)
    ) async throws -> (HTTPResponse, HTTPBody?) {
        var request = request
        request.headerFields[.acceptLanguage] = language
        return try await next(request, body, baseURL)
    }
}

/// Der generierte Client kodiert Header-Parameter wie URI-Werte (`"v1"` → `%22v1%22`).
/// ETags stehen per HTTP-Spezifikation in Anführungszeichen, ein so kodiertes `If-None-Match` würde
/// der Server nie wiedererkennen (immer 200 statt 304). Diese Middleware stellt den Rohwert wieder her.
public struct HeaderDecodingMiddleware: ClientMiddleware {
    static let rawHeaders: [HTTPField.Name] = [.ifNoneMatch, .ifMatch]

    public init() {}

    public func intercept(
        _ request: HTTPRequest,
        body: HTTPBody?,
        baseURL: URL,
        operationID: String,
        next: @Sendable (HTTPRequest, HTTPBody?, URL) async throws -> (HTTPResponse, HTTPBody?)
    ) async throws -> (HTTPResponse, HTTPBody?) {
        var request = request
        for name in Self.rawHeaders {
            if let value = request.headerFields[name], let decoded = value.removingPercentEncoding {
                request.headerFields[name] = decoded
            }
        }
        return try await next(request, body, baseURL)
    }
}
