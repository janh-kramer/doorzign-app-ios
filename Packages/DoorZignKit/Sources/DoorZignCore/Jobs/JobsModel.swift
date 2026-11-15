import DoorZignAPI
import Foundation
import Observation
import OpenAPIRuntime

/// Filter der Auftragsliste (ui-spec §7).
public enum JobFilter: String, CaseIterable, Identifiable, Sendable {
    case all, open, failed
    public var id: Self { self }

    public var label: String {
        switch self {
        case .all: L("Alle")
        case .open: L("Offen")
        case .failed: L("Fehlgeschlagen")
        }
    }

    public func matches(_ job: Job, now: Date = Date()) -> Bool {
        switch self {
        case .all: true
        case .open: job.status.isOpen
        case .failed: job.status.isFailure
        }
    }
}

/// Aufträge eines Displays oder über alle sichtbaren Displays.
@MainActor
@Observable
public final class JobsModel {
    public enum Scope: Hashable, Sendable {
        case display(String)
        case all
    }

    public let scope: Scope
    public private(set) var jobs: [Job] = []
    public private(set) var isLoading = false
    public private(set) var hasLoaded = false
    public private(set) var error: APIError?
    /// Global (Edge-Verbund): nicht alle Gateways erreichbar.
    public private(set) var incomplete = false
    public private(set) var lastUpdated: Date?
    public var filter: JobFilter = .all

    @ObservationIgnored private let client: Client
    @ObservationIgnored private var etag: String?
    @ObservationIgnored private var fastPollingSince: Date?

    public init(scope: Scope, client: Client) {
        self.scope = scope
        self.client = client
    }

    // MARK: Abgeleitet

    public var hasOpenJobs: Bool { jobs.contains { $0.isActive() } }

    /// Abschnitte: aktive (offen und fällig), geplante (Zukunft), abgeschlossene – je neueste zuerst.
    public struct Sections: Equatable, Sendable {
        public var active: [Job] = []
        public var scheduled: [Job] = []
        public var finished: [Job] = []
        public var isEmpty: Bool { active.isEmpty && scheduled.isEmpty && finished.isEmpty }
    }

    public func sections(now: Date = Date()) -> Sections {
        var result = Sections()
        for job in jobs where filter.matches(job, now: now) {
            if job.isActive(now: now) {
                result.active.append(job)
            } else if job.status.isOpen {
                result.scheduled.append(job)
            } else {
                result.finished.append(job)
            }
        }
        result.scheduled.sort { ($0.scheduledAt ?? $0.createdAt) < ($1.scheduledAt ?? $1.createdAt) }
        return result
    }

    public func count(for filter: JobFilter) -> Int { jobs.filter { filter.matches($0) }.count }

    // MARK: Laden

    public func load() async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            switch scope {
            case .display(let displayId):
                let list = try expect(try await client.listDisplayJobs(path: .init(displayId: displayId))) {
                    try $0.ok.body.json.data
                }
                jobs = Self.sorted(list)
            case .all:
                let output = try await client.listJobs(headers: .init(ifNoneMatch: hasLoaded ? etag : nil))
                switch output {
                case .ok(let ok):
                    let body = try ok.body.json
                    jobs = Self.sorted(body.data)
                    incomplete = body.incomplete ?? false
                    etag = ok.headers.eTag
                case .notModified:
                    break
                default:
                    throw APIError.from(output: output) ?? APIError.unexpected(statusCode: 0)
                }
            }
            hasLoaded = true
            lastUpdated = Date()
            error = nil
        } catch {
            let apiError = APIError.from(error)
            if apiError.code != "cancelled" { self.error = apiError }
        }
        updatePollingState()
    }

    static func sorted(_ list: [Job]) -> [Job] {
        list.sorted { $0.createdAt > $1.createdAt }
    }

    private func updatePollingState(now: Date = Date()) {
        if hasOpenJobs {
            if fastPollingSince == nil { fastPollingSince = now }
        } else {
            fastPollingSince = nil
        }
    }

    /// Aktuelles Polling-Intervall (5 s bei offenen Aufträgen, max. 5 min; sonst 30 s).
    public var pollingInterval: Duration {
        JobPolling.interval(hasOpenJobs: hasOpenJobs, fastSince: fastPollingSince)
    }

    /// Lädt sofort und dann nach der Polling-Regel, bis die Task abgebrochen wird.
    public func autoRefresh() async {
        await load()
        while !Task.isCancelled {
            try? await Task.sleep(for: pollingInterval)
            guard !Task.isCancelled else { return }
            await load()
        }
    }
}

extension Job {
    /// Fehlertext: Meldung des Backends, sonst eine Beschreibung des Fehlercodes.
    public var errorText: String? {
        if let message = errorMessage?.trimmingCharacters(in: .whitespacesAndNewlines), !message.isEmpty {
            return message
        }
        guard let code = errorCode, !code.isEmpty else { return nil }
        return switch code {
        case "transport": L("Funkverbindung gestört.")
        case "device_rejected": L("Das Display hat den Auftrag abgelehnt.")
        case "unlicensed": L("Keine gültige Lizenz.")
        case "not_in_range": L("Display außer Reichweite.")
        case "interrupted": L("Übertragung unterbrochen.")
        case "render_failed": L("Inhalt konnte nicht erzeugt werden.")
        default: L("Fehler (\(code)).")
        }
    }
}
