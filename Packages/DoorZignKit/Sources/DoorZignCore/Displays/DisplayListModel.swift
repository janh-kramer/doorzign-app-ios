import DoorZignAPI
import Foundation
import Observation
import OpenAPIRuntime

/// Zustand der Displayliste (Startseite). Lädt mit ETag; bei 304 bleibt die Liste unverändert.
@MainActor
@Observable
public final class DisplayListModel {
    public private(set) var displays: [Display] = []
    public private(set) var isLoading = false
    /// Noch nie erfolgreich geladen.
    public private(set) var hasLoaded = false
    /// Letzter Ladefehler; die zuletzt geladene Liste bleibt sichtbar.
    public private(set) var error: APIError?
    public private(set) var lastUpdated: Date?

    public var filter: DisplayFilter = .all
    public var search = ""

    /// Intervall der automatischen Aktualisierung, solange die Liste sichtbar ist.
    public static let refreshInterval: Duration = .seconds(30)

    @ObservationIgnored private let client: Client
    @ObservationIgnored private var etag: String?

    public init(client: Client) {
        self.client = client
    }

    public var visibleDisplays: [Display] {
        DisplayListLogic.apply(displays, filter: filter, search: search)
    }

    public func count(for filter: DisplayFilter) -> Int {
        displays.filter(filter.matches).count
    }

    public func load() async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let output = try await client.listDisplays(headers: .init(ifNoneMatch: hasLoaded ? etag : nil))
            switch output {
            case .ok(let ok):
                displays = try ok.body.json.data
                etag = ok.headers.eTag
            case .notModified:
                break
            default:
                throw APIError.from(output: output) ?? APIError.unexpected(statusCode: 0)
            }
            hasLoaded = true
            lastUpdated = Date()
            error = nil
        } catch {
            let apiError = APIError.from(error)
            if apiError.code != "cancelled" { self.error = apiError }
        }
    }

    /// Lädt sofort und dann periodisch, bis die aufrufende Task abgebrochen wird (`.task` in SwiftUI).
    public func autoRefresh() async {
        while !Task.isCancelled {
            await load()
            try? await Task.sleep(for: Self.refreshInterval)
        }
    }

    /// Ersetzt ein einzelnes Display (z. B. nach Aktionen im Detail).
    public func update(_ display: Display) {
        if let index = displays.firstIndex(where: { $0.id == display.id }) {
            displays[index] = display
        }
    }
}
