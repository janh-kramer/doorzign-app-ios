import DoorZignAPI
import Foundation
import Observation
import OpenAPIRuntime

/// Zeitpläne eines Displays: Liste, Anlegen, Ändern (If-Match → 412), Löschen, Aktiv-Schalter.
@MainActor
@Observable
public final class SchedulesModel {
    public let displayId: String
    public private(set) var schedules: [Schedule] = []
    public private(set) var isLoading = false
    public private(set) var hasLoaded = false
    public private(set) var error: APIError?
    /// IDs, deren Aktiv-Schalter gerade gespeichert wird.
    public private(set) var togglingIds: Set<String> = []

    public enum SaveResult: Equatable, Sendable {
        case saved(Schedule)
        /// 412: inzwischen von jemand anderem geändert.
        case conflict
        case failed(APIError)
    }

    @ObservationIgnored private let client: Client

    public init(displayId: String, client: Client) {
        self.displayId = displayId
        self.client = client
    }

    /// Sortiert nach Priorität (hoch zuerst), dann Beginn.
    public static func sorted(_ list: [Schedule]) -> [Schedule] {
        list.sorted { a, b in
            if a.priority != b.priority { return a.priority > b.priority }
            return a.start < b.start
        }
    }

    public func load() async {
        isLoading = true
        defer { isLoading = false }
        do {
            let list = try expect(try await client.listSchedules(path: .init(displayId: displayId))) { try $0.ok.body.json.data }
            schedules = Self.sorted(list)
            hasLoaded = true
            error = nil
        } catch {
            let apiError = APIError.from(error)
            if apiError.code != "cancelled" { self.error = apiError }
        }
    }

    /// Anlegen (`existing == nil`) oder Ändern mit `If-Match` (außer `overwrite`).
    public func save(_ draft: ScheduleDraft, existing: Schedule?, overwrite: Bool = false) async -> SaveResult {
        do {
            let saved: Schedule
            if let existing {
                let output = try await client.updateSchedule(
                    path: .init(scheduleId: existing.id),
                    headers: .init(ifMatch: overwrite ? nil : existing.etag),
                    body: .json(draft.input)
                )
                if case .preconditionFailed = output { return .conflict }
                saved = try expect(output) { try $0.ok.body.json }
            } else {
                saved = try expect(try await client.createSchedule(
                    path: .init(displayId: displayId),
                    body: .json(draft.input)
                )) { try $0.created.body.json }
            }
            replace(saved)
            return .saved(saved)
        } catch {
            return .failed(APIError.from(error))
        }
    }

    public func delete(_ schedule: Schedule) async -> APIError? {
        do {
            _ = try expect(try await client.deleteSchedule(path: .init(scheduleId: schedule.id))) { try $0.noContent }
            schedules.removeAll { $0.id == schedule.id }
            return nil
        } catch {
            return APIError.from(error)
        }
    }

    /// Aktiv-Schalter direkt in der Liste. Bei 412 wird neu geladen.
    public func setEnabled(_ enabled: Bool, for schedule: Schedule) async -> APIError? {
        var draft = ScheduleDraft(schedule)
        draft.enabled = enabled
        togglingIds.insert(schedule.id)
        defer { togglingIds.remove(schedule.id) }
        switch await save(draft, existing: schedule) {
        case .saved:
            return nil
        case .conflict:
            await load()
            return APIError(code: "conflict", message: "Der Zeitplan wurde inzwischen geändert. Die Liste wurde neu geladen.", statusCode: 412)
        case .failed(let error):
            return error
        }
    }

    private func replace(_ schedule: Schedule) {
        if let index = schedules.firstIndex(where: { $0.id == schedule.id }) {
            schedules[index] = schedule
        } else {
            schedules.append(schedule)
        }
        schedules = Self.sorted(schedules)
    }
}
