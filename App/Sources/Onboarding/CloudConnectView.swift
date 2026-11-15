import DoorZignCore
import SwiftUI

/// Onboarding Cloud: Instanz eingeben (oder Verbindungs-QR-Code scannen, falls vorhanden).
struct CloudConnectView: View {
    @Environment(AppSession.self) private var session
    @Environment(OnboardingModel.self) private var model
    @State private var instance = ""
    @State private var showScanner = false

    var body: some View {
        Form {
            Section {
                HStack(spacing: 0) {
                    TextField("firma", text: $instance)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                        .submitLabel(.go)
                        .onSubmit(connect)
                    if !instance.contains(".") && !instance.contains("://") {
                        Text(".zeitwart.de").foregroundStyle(.secondary)
                    }
                }
                Button("Weiter", action: connect)
                    .disabled(instance.trimmingCharacters(in: .whitespaces).isEmpty)
            } header: {
                Text("Instanz")
            } footer: {
                Text("Name deiner Zeitwart-Instanz oder die vollständige Adresse.")
            }

            ErrorSection(message: model.errorMessage)

            // Keine Zeitwart-Menünamen in App-Texten (Koordination 2026-11-15): Zeitwart bietet (noch) keinen QR-Code.
            Section {
                Button {
                    showScanner = true
                } label: {
                    Label("QR-Code scannen", systemImage: "qrcode.viewfinder")
                }
            }
        }
        .navigationTitle("Zeitwart Cloud")
        .sheet(isPresented: $showScanner) {
            QRScannerSheet { code in
                showScanner = false
                Task { await model.connect(scannedCode: code, session: session) }
            }
        }
    }

    private func connect() {
        Task { await model.connectCloud(input: instance, session: session) }
    }
}
