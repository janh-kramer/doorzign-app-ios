import DoorZignCore
import SwiftUI

/// Ad-hoc-Nachricht (ui-spec §5): Text, Dauer (Standard 60 min), „Jetzt anzeigen“; laufende Nachricht mit Restzeit.
struct AdhocView: View {
    let onChange: () -> Void
    @State private var model: AdhocModel
    @State private var confirmEnd = false
    @Environment(\.dismiss) private var dismiss

    init(context: SignedInContext, displayId: String, onChange: @escaping () -> Void) {
        self.onChange = onChange
        _model = State(initialValue: AdhocModel(displayId: displayId, client: context.client))
    }

    var body: some View {
        @Bindable var model = model
        Form {
            if let running = model.running, model.isRunning() {
                Section {
                    VStack(alignment: .leading, spacing: 4) {
                        if let headline = running.content.headline, !headline.isEmpty {
                            Text(headline).font(.headline)
                        }
                        if let message = running.content.message, !message.isEmpty {
                            Text(message)
                        }
                        HStack(spacing: 4) {
                            Text("Noch")
                            Text(timerInterval: Date()...running.endsAt, countsDown: true).monospacedDigit()
                            Text("· bis \(running.endsAt.formatted(date: .omitted, time: .shortened)) Uhr")
                        }
                        .font(.caption).foregroundStyle(.secondary)
                    }
                    Button("Beenden", role: .destructive) { confirmEnd = true }
                        .disabled(model.isSubmitting)
                } header: {
                    Text("Läuft gerade")
                } footer: {
                    Text("Eine neue Nachricht ersetzt die laufende.")
                }
            }

            if let error = model.error {
                Section {
                    Text(error.message).foregroundStyle(.red)
                    ForEach(error.fields.sorted(by: { $0.key < $1.key }), id: \.key) { _, messages in
                        ForEach(messages, id: \.self) { Text($0).font(.caption).foregroundStyle(.red) }
                    }
                }
            }

            TextContentFields(text: $model.text)

            Section {
                Picker("Dauer", selection: $model.durationMinutes) {
                    ForEach(AdhocModel.durations, id: \.self) { minutes in
                        Text(AdhocModel.label(minutes: minutes)).tag(minutes)
                    }
                }
            } footer: {
                Text("Die Nachricht ersetzt vorübergehend alle Textansichten. Bild- und Kalenderansichten bleiben unverändert.")
            }

            Section {
                Button {
                    Task {
                        if await model.start() != nil {
                            onChange()
                            dismiss()
                        }
                    }
                } label: {
                    HStack {
                        Spacer()
                        if model.isSubmitting { ProgressView() } else { Text("Jetzt anzeigen").font(.headline) }
                        Spacer()
                    }
                }
                .disabled(!model.canStart)
            } footer: {
                if !model.text.hasText {
                    Text("Bitte mindestens ein Textfeld ausfüllen.")
                }
            }
        }
        .navigationTitle("Ad-hoc-Nachricht")
        .navigationBarTitleDisplayMode(.inline)
        .task { await model.load() }
        .confirmationDialog("Ad-hoc-Nachricht beenden?", isPresented: $confirmEnd, titleVisibility: .visible) {
            Button("Beenden", role: .destructive) {
                Task {
                    if await model.end() { onChange() }
                }
            }
        }
    }
}
