import DoorZignAPI
import Foundation
import OpenAPIRuntime

extension APIError {
    /// Holt aus einer beliebigen generierten `Output`-Antwort, die nicht die erwartete ist,
    /// den `ErrorResponse` (alle Fehlerantworten des Vertrags tragen ihn) samt Statuscode.
    /// Spart pro Aufruf ein vollständiges `switch` über alle Fehlerfälle.
    public static func from(output: Any) -> APIError? {
        var statusCode: Int?
        var found: Components.Schemas.ErrorResponse?

        func visit(_ value: Any, depth: Int) {
            guard found == nil, depth < 6 else { return }
            if let error = value as? Components.Schemas.ErrorResponse {
                found = error
                return
            }
            let mirror = Mirror(reflecting: value)
            for child in mirror.children {
                if child.label == "statusCode", let code = child.value as? Int { statusCode = code }
                visit(child.value, depth: depth + 1)
            }
        }
        visit(output, depth: 0)
        if let found {
            return APIError(found, statusCode: statusCode ?? Self.statusCode(forCaseOf: output))
        }
        if let statusCode { return .unexpected(statusCode: statusCode) }
        return nil
    }

    /// Statuscode aus dem Namen des Enum-Falls (`unauthorized` → 401 …).
    static func statusCode(forCaseOf output: Any) -> Int? {
        guard let label = Mirror(reflecting: output).children.first?.label else { return nil }
        return [
            "badRequest": 400, "unauthorized": 401, "forbidden": 403, "notFound": 404, "conflict": 409,
            "preconditionFailed": 412, "contentTooLarge": 413, "unprocessableContent": 422,
            "tooManyRequests": 429, "serviceUnavailable": 503,
        ][label]
    }
}

/// Bricht `operation` nach `seconds` ab.
public func withTimeout<T: Sendable>(seconds: Double, _ operation: @escaping @Sendable () async throws -> T) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await operation() }
        group.addTask {
            try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            throw URLError(.timedOut)
        }
        defer { group.cancelAll() }
        return try await group.next()!
    }
}

/// Liefert den Wert der erwarteten Antwort oder wirft den Vertragsfehler als `APIError`.
///
///     let display = try expect(try await client.getDisplay(path: …)) { try $0.ok.body.json }
public func expect<Output, Value>(_ output: Output, _ extract: (Output) throws -> Value) throws -> Value {
    do {
        return try extract(output)
    } catch {
        throw APIError.from(output: output) ?? APIError.from(error)
    }
}
