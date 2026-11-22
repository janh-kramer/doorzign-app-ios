import DoorZignAPI
import DoorZignCore
import SwiftUI

/// Startseite: alle sichtbaren Displays mit Suche, Filter, Pull-to-Refresh und Aktualisierung alle 30 s.
struct DisplayListView: View {
    let context: SignedInContext
    @State private var model: DisplayListModel

    init(context: SignedInContext) {
        self.context = context
        _model = State(initialValue: DisplayListModel(client: context.client))
    }

    var body: some View {
        @Bindable var model = model
        List {
            if let error = model.error {
                Section {
                    Label(error.message, systemImage: "wifi.exclamationmark")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
            ForEach(model.visibleDisplays, id: \.id) { display in
                NavigationLink(value: display.id) {
                    DisplayRow(display: display, previews: context.previews)
                }
                .accessibilityIdentifier("display.row")
            }
        }
        .listStyle(.plain)
        .overlay { emptyState }
        .navigationTitle("Displays")
        .searchable(text: $model.search, prompt: "Name, Ort oder MAC")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) { filterMenu }
        }
        .topBar {
            if model.filter != .all {
                FilterBanner(filter: model.filter) { model.filter = .all }
            }
        }
        .refreshable { await model.load() }
        // Aktualisiert nur, solange die Liste sichtbar ist (Task endet beim Verlassen).
        .task { await model.autoRefresh() }
        .navigationDestination(for: String.self) { id in
            DisplayDetailView(context: context, displayId: id, initial: model.displays.first { $0.id == id })
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        if !model.hasLoaded && model.error == nil {
            ProgressView()
        } else if model.hasLoaded && model.visibleDisplays.isEmpty {
            if model.displays.isEmpty {
                ContentUnavailableView("Keine Displays", systemImage: "rectangle.portrait.slash",
                                       description: Text("Dir sind noch keine Displays freigegeben."))
            } else if !model.search.isEmpty {
                ContentUnavailableView.search(text: model.search)
            } else {
                ContentUnavailableView("Keine Treffer", systemImage: "line.3.horizontal.decrease.circle",
                                       description: Text("Kein Display entspricht dem Filter „\(model.filter.label)“."))
            }
        }
    }

    private var filterMenu: some View {
        Menu {
            Picker("Filter", selection: $model.filter) {
                ForEach(DisplayFilter.allCases) { filter in
                    Text("\(filter.label) (\(model.count(for: filter)))").tag(filter)
                }
            }
        } label: {
            Image(systemName: model.filter == .all
                  ? "line.3.horizontal.decrease.circle"
                  : "line.3.horizontal.decrease.circle.fill")
        }
        .accessibilityLabel("Filter")
    }
}

private struct FilterBanner: View {
    let filter: DisplayFilter
    let reset: () -> Void

    var body: some View {
        HStack {
            Text("Filter: \(filter.label)").font(.footnote.weight(.medium))
            Spacer()
            Button("Zurücksetzen", action: reset).font(.footnote)
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
    }
}

/// Eine Zeile: Miniatur, Name, Ort, Status, Akku, Signal, Hinweise.
struct DisplayRow: View {
    let display: Display
    let previews: PreviewLoader

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            PreviewThumbnail(
                previews: previews,
                displayId: display.id,
                slot: display.activeSlot,
                etag: display.activePreviewEtag,
                rotate: display.rotate
            )
            .frame(width: 64, height: 64)

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(display.name).font(.headline).lineLimit(1)
                    Spacer(minLength: 4)
                    OnlineChip(online: display.online)
                }
                if let location = display.location, !location.isEmpty {
                    Text(location).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                }
                HStack(spacing: 12) {
                    BatteryIndicator(percent: display.battery)
                    SignalIndicator(rssi: display.signal)
                }
                .font(.caption)
                if display.openJobs > 0 {
                    Label("Wird übertragen …", systemImage: "arrow.up.circle")
                        .font(.caption).foregroundStyle(.blue)
                } else if let error = display.lastError, !error.isEmpty {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .font(.caption).foregroundStyle(.red).lineLimit(2)
                }
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }
}

struct OnlineChip: View {
    let online: Bool

    var body: some View {
        Text(online ? "Online" : "Offline")
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background((online ? Color.green : Color.gray).opacity(0.18), in: Capsule())
            .foregroundStyle(online ? Color.green : Color.secondary)
    }
}

struct BatteryIndicator: View {
    let percent: Int?

    var body: some View {
        let level = BatteryLevel(percent: percent)
        Label {
            Text(percent.map { "\($0) %" } ?? level.label)
        } icon: {
            Image(systemName: Self.symbol(percent))
        }
        .foregroundStyle(level == .critical ? Color.red : level == .low ? Color.orange : Color.secondary)
        .accessibilityLabel("Akku \(percent.map { String(localized: "\($0) Prozent") } ?? level.label)")
    }

    static func symbol(_ percent: Int?) -> String {
        switch percent {
        case nil: "battery.0percent"
        case let p? where p < 15: "battery.0percent"
        case let p? where p < 40: "battery.25percent"
        case let p? where p < 65: "battery.50percent"
        case let p? where p < 90: "battery.75percent"
        default: "battery.100percent"
        }
    }
}

struct SignalIndicator: View {
    let rssi: Int?

    var body: some View {
        let quality = SignalQuality(rssi: rssi)
        Label {
            Text(quality.label)
        } icon: {
            Image(systemName: "cellularbars", variableValue: Double(quality.bars) / 3)
        }
        .foregroundStyle(quality == .weak ? Color.orange : Color.secondary)
        .accessibilityLabel("Signal \(quality.label)")
    }
}

/// Vorschau-PNG einer Ansicht; lädt über den `PreviewLoader` (Bearer, ETag-Cache).
struct PreviewThumbnail: View {
    let previews: PreviewLoader
    let displayId: String
    let slot: Int
    let etag: String?
    var rotate: Int = 0
    /// Zusätzlicher Auslöser zum Neuladen, z. B. `Slot.etag` (Inhalt geändert).
    var refreshKey: String?

    @State private var data: Data?
    @State private var loaded = false

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 6).fill(Color.white)
            if etag == nil {
                // Vertrag 1.2.3: kein previewEtag → keine Vorschau (deaktiviert oder Bild fehlt).
                Image(systemName: "eye.slash").foregroundStyle(.tertiary)
            } else if let data, UIImage(data: data) != nil {
                // Flächenmittelnd verkleinert (decisions 47), Cache-Schlüssel mit ETag.
                ScaledPreviewImage(data: data, cacheKey: "\(displayId)-\(slot)-\(etag ?? "")-\(refreshKey ?? "")")
            } else if loaded {
                Image(systemName: "photo").foregroundStyle(.tertiary)
            } else {
                ProgressView().controlSize(.small)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))
        .task(id: "\(displayId)-\(slot)-\(etag ?? "")-\(refreshKey ?? "")") {
            data = await previews.preview(displayId: displayId, slot: slot, expectedEtag: etag)
            loaded = true
        }
        .accessibilityLabel(etag == nil ? "Keine Vorschau für Ansicht \(slot)" : "Vorschau Ansicht \(slot)")
    }
}
