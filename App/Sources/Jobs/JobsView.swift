import DoorZignAPI
import DoorZignCore
import SwiftUI

/// Übertragungen (ui-spec §7): Aufträge pro Display oder über alle Displays, mit Status, Fehlertext,
/// nächstem Versuch. Aktualisiert sich nach der Polling-Regel, solange sichtbar.
struct JobsView: View {
    let context: SignedInContext
    let title: String?
    /// MAC zu einer Display-ID, falls bekannt – für Aufträge an Displays ohne Namen (decisions 48).
    let macForDisplay: (String) -> String?
    @State private var model: JobsModel

    init(context: SignedInContext, scope: JobsModel.Scope, title: String?,
         macForDisplay: @escaping (String) -> String? = { _ in nil }) {
        self.context = context
        self.title = title
        self.macForDisplay = macForDisplay
        _model = State(initialValue: JobsModel(scope: scope, client: context.client))
    }

    private var isGlobal: Bool { model.scope == .all }

    var body: some View {
        @Bindable var model = model
        let sections = model.sections()
        List {
            if let error = model.error {
                ErrorSection(message: error.message)
            }
            if model.incomplete {
                Section {
                    Label("Nicht alle Gateways waren erreichbar. Die Liste ist möglicherweise unvollständig.",
                          systemImage: "exclamationmark.triangle")
                        .font(.callout)
                        .foregroundStyle(.orange)
                }
            }
            if model.hasLoaded && sections.isEmpty {
                ContentUnavailableView(
                    model.filter == .all ? "Keine Aufträge" : "Keine passenden Aufträge",
                    systemImage: "checkmark.circle",
                    description: Text(model.filter == .all
                                      ? "Es wurden zuletzt keine Inhalte übertragen."
                                      : "Für diesen Filter gibt es keine Aufträge.")
                )
                .listRowBackground(Color.clear)
            }
            section("Laufend", sections.active)
            section("Geplant", sections.scheduled)
            section("Abgeschlossen", sections.finished)
        }
        .overlay { if !model.hasLoaded && model.error == nil { ProgressView() } }
        .navigationTitle(isGlobal ? "Übertragungen" : "Aufträge")
        .navigationBarTitleDisplayMode(isGlobal ? .large : .inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Picker("Filter", selection: $model.filter) {
                        ForEach(JobFilter.allCases) { filter in
                            Text("\(filter.label) (\(model.count(for: filter)))").tag(filter)
                        }
                    }
                } label: {
                    Label("Filter", systemImage: model.filter == .all
                          ? "line.3.horizontal.decrease.circle" : "line.3.horizontal.decrease.circle.fill")
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            if let title, !isGlobal {
                Text(title).font(.caption).foregroundStyle(.secondary).padding(.bottom, 4)
            }
        }
        .refreshable { await model.load() }
        .task { await model.autoRefresh() }
    }

    @ViewBuilder
    private func section(_ title: LocalizedStringKey, _ jobs: [Job]) -> some View {
        if !jobs.isEmpty {
            Section(title) {
                ForEach(jobs, id: \.id) { job in
                    if isGlobal {
                        NavigationLink(value: job.displayId) {
                            JobRow(job: job, displayLabel: job.displayLabel(mac: macForDisplay(job.displayId)))
                        }
                    } else {
                        JobRow(job: job)
                    }
                }
            }
        }
    }
}

/// Zeile eines Auftrags: Art, Status, ggf. Display, Fehlertext, Zeitpunkt bzw. nächster Versuch.
struct JobRow: View {
    let job: Job
    /// Angezeigter Displayname (nur in der globalen Liste).
    var displayLabel: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline) {
                Text(job.typeLabel)
                Spacer()
                Text(job.status.label)
                    .font(.caption)
                    .foregroundStyle(job.status.isFailure ? Color.red : job.status.isOpen ? Color.blue : Color.secondary)
            }
            if let displayLabel {
                Text(displayLabel).font(.caption).foregroundStyle(.secondary)
            }
            if let text = job.errorText, job.status.isFailure || job.status == .retry {
                Text(text).font(.caption).foregroundStyle(job.status.isFailure ? Color.red : Color.orange)
            }
            HStack(spacing: 6) {
                if let scheduled = job.scheduledAt, scheduled > Date() {
                    Text("Geplant für \(scheduled, format: .dateTime.day().month().hour().minute())")
                } else if job.status == .retry, let next = job.nextTryAt {
                    Text("Nächster Versuch \(next, format: .relative(presentation: .named))")
                } else {
                    Text(job.doneAt ?? job.updatedAt ?? job.createdAt, format: .relative(presentation: .named))
                }
                if let tries = job.tries, tries > 1 {
                    Text("· Versuche: \(tries)")
                }
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }
}
