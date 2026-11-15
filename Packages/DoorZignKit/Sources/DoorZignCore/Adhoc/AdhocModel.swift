import DoorZignAPI
import Foundation
import Observation
import OpenAPIRuntime

/// Ad-hoc-Nachricht (ui-spec §5): Text wie eine Textansicht, feste Dauern, ersetzt eine laufende Nachricht.
@MainActor
@Observable
public final class AdhocModel {
    /// Erlaubte Dauern laut Vertrag (andere Werte → 422).
    public static let durations = [15, 30, 45, 60, 90, 120, 180, 240]
    public static let defaultDuration = 60

    public let displayId: String
    public var text = SlotDraft.Text()
    public var durationMinutes = AdhocModel.defaultDuration

    public private(set) var running: Adhoc?
    public private(set) var isLoading = false
    public private(set) var isSubmitting = false
    public private(set) var error: APIError?

    @ObservationIgnored private let client: Client

    public init(displayId: String, client: Client) {
        self.displayId = displayId
        self.client = client
    }

    public var canStart: Bool {
        text.isValid && text.hasText && Self.durations.contains(durationMinutes) && !isSubmitting
    }

    /// Läuft gerade eine Nachricht (Ende in der Zukunft)?
    public func isRunning(now: Date = Date()) -> Bool {
        running.map { $0.endsAt > now } ?? false
    }

    /// Lädt die laufende Nachricht und übernimmt deren Text als Ausgangspunkt zum Ersetzen.
    public func load() async {
        isLoading = true
        defer { isLoading = false }
        do {
            let output = try await client.getAdhoc(path: .init(displayId: displayId))
            switch output {
            case .ok(let ok):
                let adhoc = try ok.body.json
                running = adhoc
                if !text.hasText { text = SlotDraft.Text(adhoc.content) }
            case .noContent:
                running = nil
            default:
                throw APIError.from(output: output) ?? APIError.unexpected(statusCode: 0)
            }
            error = nil
        } catch {
            self.error = APIError.from(error)
        }
    }

    /// „Jetzt anzeigen“ – ersetzt eine laufende Nachricht.
    @discardableResult
    public func start() async -> Adhoc? {
        guard canStart else { return nil }
        isSubmitting = true
        error = nil
        defer { isSubmitting = false }
        do {
            let adhoc = try expect(try await client.startAdhoc(
                path: .init(displayId: displayId),
                body: .json(.init(content: text.textContent, durationMinutes: durationMinutes))
            )) { try $0.created.body.json }
            running = adhoc
            return adhoc
        } catch {
            self.error = APIError.from(error)
            return nil
        }
    }

    /// Laufende Nachricht beenden.
    @discardableResult
    public func end() async -> Bool {
        isSubmitting = true
        error = nil
        defer { isSubmitting = false }
        do {
            _ = try expect(try await client.endAdhoc(path: .init(displayId: displayId))) { try $0.noContent }
            running = nil
            return true
        } catch {
            self.error = APIError.from(error)
            return false
        }
    }

    /// Dauer lesbar: 90 → „1 Std. 30 Min.“.
    public static func label(minutes: Int) -> String {
        let hours = minutes / 60, rest = minutes % 60
        switch (hours, rest) {
        case (0, _): return "\(rest) Min."
        case (_, 0): return "\(hours) Std."
        default: return "\(hours) Std. \(rest) Min."
        }
    }
}
